# UrbanConnect — Infrastructure Kubernetes

Manifests de déploiement production d'UrbanConnect. Transposition du stack Docker
Compose actif (`docker-compose.yml`) vers Kubernetes, avec durcissement edge
(Traefik + Oathkeeper + CrowdSec).

> Namespace applicatif : `urbanconnect`. Déploiement via **Kustomize** :
> `kubectl apply -k kube/`.

---

## 1. Vue d'ensemble

```
                          Internet (IP externe)
                                  │
                    ┌─────────────▼─────────────┐
                    │   (amont) DDoS L3/L4        │  ← Cloudflare / DDoS LB cloud
                    │   NON fourni ici            │     (protection volumétrique)
                    └─────────────┬─────────────┘
                                  │
                    ┌─────────────▼─────────────┐
                    │        Traefik (Helm)      │  entrypoint web/websecure, ACME
                    └─────────────┬─────────────┘
                                  │  chaîne de middlewares « master »
                    ┌─────────────▼─────────────┐
                    │  CrowdSec  (bouncer + WAF) │  ← rejette IP/requêtes malveillantes
                    └─────────────┬─────────────┘
                                  │  (API uniquement)
                    ┌─────────────▼─────────────┐
                    │  Oathkeeper (forward-auth) │  ← valide la session Kratos à l'edge
                    └─────────────┬─────────────┘
                                  │
      ┌───────────────────────────┼───────────────────────────┐
      ▼                           ▼                           ▼
   frontend                    backend (API)                kratos / directus /
   (Next.js)                   (NestJS + GraphQL)           minio / nominatim / pgadmin
                                  │
             ┌────────────────────┼────────────────────┐
             ▼                    ▼                    ▼
      Postgres (pgbouncer)    Redis            Couche async
                                               ├─ Kafka (événementiel/fanout)
                                               └─ Temporal (+worker)
                                                     workflows durables / crons
      coturn (DaemonSet hostNetwork) ── STUN/TURN pour appels WebRTC
```

### Couches

| Couche | Composants |
|---|---|
| **Edge / sécurité** | Traefik (ingress), CrowdSec (bouncer + AppSec/WAF), Oathkeeper (forward-auth Kratos) |
| **Application** | frontend (Next.js), backend (NestJS), temporal-worker |
| **Auth** | Kratos (+ migrate-job) |
| **Data** | postgres unique (app + kratos + temporal + directus, image `postgis/postgis:16-3.5`) + pgbouncer, redis |
| **Async** | Kafka, Temporal (+ temporal-worker), UIs kafka-ui / temporal-ui |
| **Recherche** | Elasticsearch (index de lecture recherche + feeds, fallback Postgres auto), Kibana |
| **Services** | MinIO (S3), Nominatim (+ postgres-nominatim, Postgres dédié), Directus |
| **WebRTC** | coturn (STUN/TURN) |
| **Ops** | geoipupdate (CronJob MaxMind), pgadmin |

---

## 2. Ingress — Istio

Le pattern master/children de Traefik a disparu avec lui. Istio sépare
nativement ce que l'`IngressRoute` mêlait :

- `ingress/gateway.yaml` — les 14 hosts servis, et le TLS de la passerelle.
- `ingress/virtualservices.yaml` — un VirtualService par host, routage seul.
- `ingress/authorization.yaml` — la politique, séparée du routage. Elle vit
  dans le namespace `istio-ingress`, auprès des pods de la passerelle : c'est
  le seul endroit où l'ext_authz L7 s'applique en mode ambient, `ztunnel` ne
  faisant que du L4. Elle est donc appliquée **hors kustomize**, par le
  playbook.

Ajouter un outil = un VirtualService et une ligne dans les `hosts` du Gateway.

L'étiquette `uc.ingress/tier` (`public` / `internal`) est portée par chaque
VirtualService. Elle n'a aujourd'hui **aucun effet technique** : tout est déjà
restreint au LAN par nginx. Elle existe pour que publier l'applicatif un jour
soit une ligne à écrire, et non un audit à refaire.

---

## 3. Prérequis (hors `kubectl apply -k`)

Ces composants s'installent **avant** via Helm / commandes impératives.

### 3.1 Contrôleur Ingress — Traefik (ACME natif)

```bash
helm repo add traefik https://traefik.github.io/charts
helm install traefik traefik/traefik -n traefik --create-namespace \
  --set 'ports.web.redirectTo.port=websecure' \
  --set 'certificatesResolvers.letsencrypt.acme.email=admin@urbanconnect.fr' \
  --set 'certificatesResolvers.letsencrypt.acme.storage=/data/acme.json' \
  --set 'certificatesResolvers.letsencrypt.acme.tlsChallenge=true' \
  --set 'persistence.enabled=true' \
  --set 'providers.kubernetesCRD.allowCrossNamespace=true' \
  --set 'experimental.plugins.crowdsec.moduleName=github.com/maxlerebourg/crowdsec-bouncer-traefik-plugin' \
  --set 'experimental.plugins.crowdsec.version=v1.4.2'
```

> Installe aussi les **CRDs Traefik** (`IngressRoute`, `Middleware`, `TLSOption`).
> Sans elles, `apply -k` échoue sur les objets ingress.
> cert-manager **n'est plus requis** (Traefik gère Let's Encrypt).

### 3.2 CrowdSec (agent + LAPI + AppSec/WAF)

```bash
helm repo add crowdsec https://crowdsecurity.github.io/helm-charts
helm install crowdsec crowdsec/crowdsec -n crowdsec --create-namespace \
  --set agent.acquisition[0].namespace=traefik \
  --set agent.acquisition[0].podName='traefik-*' \
  --set agent.acquisition[0].program=traefik \
  --set-string 'config.collections=crowdsecurity/traefik crowdsecurity/base-http-scenarios crowdsecurity/http-cve crowdsecurity/appsec-virtual-patching crowdsecurity/appsec-generic-rules' \
  --set appsec.enabled=true

# Clé bouncer → montée comme fichier dans le pod Traefik
POD=$(kubectl get pod -n crowdsec -l app.kubernetes.io/component=lapi -o name | head -1)
kubectl exec -n crowdsec $POD -- cscli bouncers add traefik-bouncer -o raw
kubectl create secret generic crowdsec-bouncer-apikey -n traefik --from-literal=lapi-key='<CLE>'
# puis (values Traefik) monter ce secret sur /etc/traefik/crowdsec/lapi-key
```

> ⚠️ **CrowdSec ≠ anti-DDoS volumétrique.** Il couvre le L7 (scans, brute-force,
> bad bots, SQLi/XSS via WAF, réputation d'IP). La protection volumétrique L3/L4
> reste à assurer **en amont** (Cloudflare / DDoS du LB cloud).

### 3.3 ConfigMaps (montées par kratos et postgres)

```bash
kubectl create namespace urbanconnect
kubectl create configmap kratos-config --from-file=./kratos/ -n urbanconnect
kubectl create configmap postgres-init --from-file=init-db.sql -n urbanconnect
```

### 3.4 Secrets

`kube/secrets.yaml` est un **template** (`CHANGE_ME`). En prod, ne pas commiter de
vraies valeurs → **Sealed Secrets** ou **External Secrets**, ou :

```bash
kubectl create secret generic urbanconnect-secrets --from-env-file=.env.prod -n urbanconnect
```

### 3.5 Images à construire et pousser

| Image | Source | Note |
|---|---|---|
| `urbanconnect-backend:prod` | `backTs/` (target `production`) | Alpine/musl |
| `urbanconnect-frontend:prod` | `front/` | Next.js prod |
| `urbanconnect-temporal-worker:prod` | `backTs/` base **glibc** (`node:20-slim`) | ⚠️ `@temporalio/worker` incompatible musl — **pas** l'image backend Alpine |

En prod, remplacer par un registry (`registry.urbanconnect.fr/...:TAG`).

### 3.6 StorageClass

Un `StorageClass` par défaut avec `ReadWriteOnce` est requis (les StatefulSets
utilisent des `volumeClaimTemplates`). Adapter `storageClassName` selon le provider
(gp3 AWS, standard-ssd GCP, etc.). Nominatim demande du **SSD** (import lourd).

---

## 4. Déploiement

### Ordre (géré par les `depends`/probes, mais recommandé)

1. `namespace` → `secrets`
2. bases : postgres (unique : app+kratos+temporal+directus), postgres-nominatim,
   redis, minio, kafka, elasticsearch
3. pgbouncer (après postgres)
4. jobs : kratos-migrate (après postgres), minio-init (après minio),
   elasticsearch-setup (après elasticsearch — fixe le mdp `kibana_system`)
5. kratos (après migrate), temporal (auto-setup après postgres)
6. oathkeeper, directus, nominatim, kafka-ui, temporal-ui, kibana
7. backend (après pgbouncer, redis, kratos, minio, kafka, temporal, elasticsearch)
8. temporal-worker (image glibc, `SCHEDULER_BACKEND` cohérent avec backend)
9. frontend
10. coturn (DaemonSet nœuds publics), geoipupdate, pgadmin
11. ingress : master → children

### Commande

```bash
# Vérifier le rendu sans appliquer
kubectl kustomize kube/

# Appliquer
kubectl apply -k kube/

# Suivre
kubectl get pods -n urbanconnect -w
```

> **Nominatim** : le premier boot importe un extrait OSM (`nord-pas-de-calais` par
> défaut dans le compose ; le PVC est dimensionné pour l'Europe). Import **long**
> (dizaines de minutes à heures) et gourmand en RAM/disque. Le pod reste `NotReady`
> pendant l'import — c'est normal.

### Accès aux UIs internes (pas d'Ingress)

```bash
kubectl port-forward svc/kafka-ui   8080:8080 -n urbanconnect   # Kafka UI
kubectl port-forward svc/temporal-ui 8080:8080 -n urbanconnect  # Temporal UI
kubectl port-forward svc/kibana      5601:5601 -n urbanconnect  # Kibana (elastic / mdp secret)
```

---

## 5. Dimensionnement (RAM / CPU / stockage)

Chiffres **agrégés depuis les `resources` déclarées** dans les manifests
(réplicas de base : backend ×2, frontend ×2, kratos ×2, oathkeeper ×2, pgbouncer ×2 ;
le reste ×1).

### Totaux cluster (charge applicative seule)

| Métrique | Requests (garanti) | Limits (plafond) |
|---|---|---|
| **CPU** | ≈ **6,8 vCPU** | ≈ 26 vCPU |
| **RAM** | ≈ **11,6 Gi** | ≈ 33–45 Gi* |

\* Le plafond RAM haut vient de **Nominatim** (limit 16 Gi pendant l'import initial ;
~4 Gi en régime établi). Hors burst import, plafond ≈ 33 Gi.

À cela s'ajoutent (hors kustomize) : Traefik (~0,5 vCPU / 512 Mi), CrowdSec
agent+LAPI+AppSec (~0,5–1 vCPU / 1–2 Gi), et l'overhead système Kubernetes
(kubelet, CNI, DNS… ~1 vCPU / 1–2 Gi par nœud).

### Gros consommateurs

| Composant | RAM req / limit | Pourquoi |
|---|---|---|
| **nominatim** | 4 Gi / **16 Gi** | Import + index PostgreSQL OSM |
| postgres-nominatim | 1 Gi / 4 Gi | DB géocodage (~60–80 Go Europe) |
| backend ×2 | 2 × 512 Mi / 2 Gi | NestJS + Prisma + GraphQL |
| frontend ×2 | 2 × 512 Mi / 2 Gi | Next.js SSR |
| kafka | 512 Mi / 2 Gi | Broker JVM |
| **elasticsearch** | 2 Gi / 3 Gi | JVM heap 1 Gi (`ES_JAVA_OPTS`) + off-heap/Lucene |
| kibana | 512 Mi / 1,5 Gi | Node.js + navigateur headless |
| minio | 256 Mi / 2 Gi | Objets S3 |
| temporal / temporal-worker | 512 Mi / 1 Gi chacun | Moteur + worker |

### Recommandations de nœuds

| Environnement | Cluster conseillé | Commentaire |
|---|---|---|
| **Dev / staging** | 3 × (4 vCPU, **16 Go**) = 12 vCPU / 48 Go | Couvre les requests + burst Nominatim. Minimum réaliste. |
| **Production** | 3–4 × (8 vCPU, **32 Go**) = 24–32 vCPU / 96–128 Go | Marge pour HPA (backend/frontend jusqu'à 10 réplicas) + pics. |
| **Nominatim** | nœud/pool dédié ≥ **16 Go RAM + SSD** | Isoler l'import (taint/toleration) pour ne pas étouffer les autres pods. |

> **RAM minimale absolue** pour démarrer tout le stack (sans HPA, sans marge) :
> **~16 Go** schedulables — mais l'import Nominatim en réclame ~16 Go à lui seul le
> temps de l'import. En pratique, **prévoir 32–48 Go** pour un premier déploiement
> serein.

### Stockage persistant (PVC)

| PVC | Taille | | PVC | Taille |
|---|---|---|---|---|
| nominatim | 200 Gi | | postgres (unique) | 100 Gi |
| postgres-nominatim | 100 Gi | | kafka | 20 Gi |
| minio | 100 Gi | | elasticsearch | 20 Gi |
| redis | 5 Gi | | pgadmin | 2 Gi |
| geoip | 1 Gi | | | |
| | | | **Total** | **≈ 550 Gi** |

Prévoir un provisionnement dynamique (CSI) avec cette capacité + marge de croissance
(surtout minio et postgres app).

---

## 6. Scaling

- **backend / frontend** : HPA fournis (`*/hpa.yaml`), 2→10 réplicas (CPU 70 % /
  mémoire 80 %). Ajuster `maxReplicas` selon le nœud pool.
- **CrowdSec** (Helm, mono-instance ici) sous charge : monter `appsec.replicas`
  (+ HPA) — le Service AppSec load-balance, le bouncer Traefik tape la VIP ;
  rendre la **LAPI** HA (`lapi.replicas=2` + DB partagée). Aucune modif des
  manifests kustomize.
- **temporal-worker** : stateless, scaler les réplicas si les crons/workflows
  saturent (Temporal répartit les tasks). Garder `SCHEDULER_BACKEND=temporal`
  cohérent avec le backend.
- **Kafka / Postgres / MinIO** : mono-nœud ici (dev-friendly). Pour la HA prod,
  passer par des opérateurs dédiés (Strapi/Strimzi, CloudNativePG, MinIO Operator).

---

## 7. Vérification post-déploiement

```bash
kubectl get pods -n urbanconnect                 # tout Running/Ready (sauf nominatim en import)
kubectl get ingressroute,middleware,tlsoption -n urbanconnect
kubectl logs -n urbanconnect deploy/oathkeeper   # forward-auth OK
kubectl logs -n traefik deploy/traefik | grep -i crowdsec   # plugin bouncer chargé
kubectl exec -n crowdsec <lapi-pod> -- cscli metrics        # décisions/alertes
```

Tests fonctionnels :
- `https://urbanconnect.fr` → frontend (cert Let's Encrypt valide).
- `https://api.urbanconnect.fr/health` → backend (via crowdsec + oathkeeper).
- IP bannie (`cscli decisions add --ip x.x.x.x`) → 403 à l'edge.

---

## 8. Points d'attention / durcissement

- **secrets.yaml** : template — jamais de vraies valeurs en clair dans git.
- **coturn** : `hostNetwork` — cibler les nœuds à IP publique (`nodeSelector`
  commenté dans le manifest), ouvrir 3478/tcp+udp + 49160-49200/udp côté firewall.
  Dev : `--no-tls/--no-dtls` ; prod → ajouter un cert (turns:5349).
- **elasticsearch** : exige `vm.max_map_count >= 262144` sur le nœud. Le manifest
  le pose via un **initContainer privilégié** — si la PodSecurity interdit le
  `privileged`, retirer l'initContainer et poser le sysctl au niveau nœud
  (DaemonSet de tuning ou `--sysctl` kubelet). Sécurité activée (`xpack.security`) :
  auth basic `elastic` (superuser, backend/worker) + `kibana_system` (Kibana),
  mots de passe dans `urbanconnect-secrets`. Le Job `elasticsearch-setup` fixe le
  mdp `kibana_system` une fois ES prêt (Kibana refuse le superuser `elastic`).
  Pas d'Ingress pour Kibana → `port-forward` (cf. §4).
- **Consoles d'administration** (directus, minio, pgadmin, kafka, temporal,
  kibana, kiali, prometheus) : restreintes au LAN par le bloc `allow`/`deny`
  des vhosts nginx, et par des enregistrements A publics qui pointent sur une
  IP privée. Deux barrières indépendantes.
- **JWT à l'edge** (optionnel) : Oathkeeper peut minter un JWT signé (mutator
  `id_token`) pour décharger le backend — nécessite JWKS + passage HS256→RS256.
  Laissé désactivé (voir `oathkeeper/configmap.yaml`).
```
