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
   frontend                    backend (API)                kratos / minio /
   (Next.js)                   (NestJS + GraphQL)           nominatim / pgadmin
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
| **Data** | postgres unique (app + kratos + temporal, image `postgis/postgis:16-3.5`) + pgbouncer, redis |
| **Async** | Kafka, Temporal (+ temporal-worker), UIs kafka-ui / temporal-ui |
| **Recherche** | Elasticsearch (index de lecture recherche + feeds, fallback Postgres auto), Kibana |
| **Services** | MinIO (S3), Nominatim (+ postgres-nominatim, Postgres dédié) |
| **WebRTC** | coturn (STUN/TURN) |
| **Ops** | geoipupdate (CronJob MaxMind), pgadmin |

---

## 2. Ingress — Istio

Le pattern master/children de Traefik a disparu avec lui. Istio sépare
nativement ce que l'`IngressRoute` mêlait :

- `ingress/gateway.yaml` — les 16 hosts servis, et le TLS de la passerelle.
- `ingress/virtualservices.yaml` — un VirtualService par host, routage seul.
  Grafana fait exception : son VirtualService vit avec le reste de
  l'observabilité, dans `observability/ingress/`.
- `ingress/authorization.yaml` — la politique, séparée du routage. Elle vit
  dans le namespace `istio-ingress`, auprès des pods de la passerelle : c'est
  le seul endroit où l'ext_authz L7 s'applique en mode ambient, `ztunnel` ne
  faisant que du L4. Elle est donc appliquée **hors kustomize**, par le
  playbook.

Ajouter un outil demande **trois** écritures, jamais une seule :

1. un VirtualService (avec l'étiquette `uc.ingress/tier`) ;
2. le host dans les `hosts` du Gateway — **les deux `servers`**, HTTP et HTTPS.
   L'oublier ne casse pas le déploiement : la passerelle répond simplement 404
   sans jamais consulter le VirtualService ;
3. une entrée dans `edge_urbanlink_services`
   (`ansible/roles/edge_urbanlink/defaults/main.yml`), puis
   `ansible-playbook playbooks/33-urbanlink-edge.yml` — c'est le nginx du nœud
   qui termine le TLS, pas la passerelle.

Le DNS, lui, ne demande rien : le wildcard `*.urbanlink.fr → 192.168.100.50`
en DNS-only couvre déjà tout nom interne, avant même qu'il existe.

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

### 3.3 ConfigMaps — la configuration vient du dépôt applicatif

Elles sont générées par le `configMapGenerator` de `kustomization.yaml`,
déployé par **Argo CD**. Leur contenu vit dans `config/` du dépôt
**UrbanConnct**, à côté du `docker-compose.yml` qui monte les mêmes fichiers
en développement — une seule version, pour deux environnements.

> ⚠️ `kube/urbanlink/config/` est une **copie** (mirror), écrite par la CI du
> dépôt applicatif à chaque push sur `main`. La source de vérité reste
> `config/` d'UrbanConnct. **Ne rien y éditer à la main** : le `rsync --delete`
> de la prochaine livraison l'écrasera. Ce qui part réellement dans le cluster
> est ce que le `configMapGenerator` liste, et rien d'autre — la copie porte
> aussi des fichiers que rien ne monte (observability/, kratos/email/…).

| ConfigMap | Construite depuis | Déployé par / monté par |
|---|---|---|
| `kratos-config` | `common/kratos/` + `<env>/kratos/` | Argo — kratos, kratos-migrate |
| `postgres-init` | `common/postgres-init/` | Argo — postgres |
| `pgbouncer-config` | `<env>/pgbouncer/` | Argo — pgbouncer (`envFrom`) |
| `nominatim-config` | `common/nominatim/` + `<env>/nominatim/` | Argo — nominatim (`envFrom`) |
| `observability-config` | `common/observability/` + `<env>/observability/` (otel/tempo/loki) | Argo — otel-collector, tempo, loki |

`<env>` vaut `prod` par défaut (`urbanlink_env`). Le suffixe de hash ajouté par
`configMapGenerator` dépend du **contenu** : changer un fichier change le nom de
la ConfigMap et redémarre les pods qui la montent — c'est le mécanisme voulu,
pas un effet de bord (voir l'en-tête de `kustomization.yaml`).

> **Observabilité.** Les tableaux de bord Grafana (8 JSON dans
> `grafana-dashboards/`) et les sources de données (`grafana-datasources.yaml`)
> sont construits en ConfigMaps et découverts par le sidecar Grafana du
> kube-prometheus-stack, via les labels `grafana_dashboard: "1"` et
> `grafana_datasource: "1"` — posés par `options.labels` du
> `configMapGenerator`, **pas** par un `labels:` à la racine du générateur : ce
> champ court n'existe qu'à partir de kustomize 5.5, et le repo-server d'Argo
> embarque la 5.4.3, qui refuse le build entier.
>
> Le Prometheus/Grafana/Alertmanager eux-mêmes sont déployés par **Helm**
> (`ansible/roles/kubernetes/tasks/observability.yml`), pas par Argo — les
> valeurs viennent du template `kube-prometheus-stack-values.yaml.j2`. Le
> compte admin de Grafana est le compte console commun
> (`CONSOLE_ADMIN_USER` / `CONSOLE_ADMIN_PASSWORD`) ; le SMTP d'Alertmanager
> vient de `secrets.env` (clés `GRAFANA_SMTP_*`).
>
> ⚠️ **Ordre imposé** : le chart Helm installe la CRD `PrometheusRule`. Il doit
> donc passer avant qu'Argo ne synchronise `observability/prometheus-alerts.yaml`,
> sinon la synchronisation échoue sur un `kind` inconnu.

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
2. bases : postgres (unique : app+kratos+temporal), postgres-nominatim,
   redis, minio, kafka, elasticsearch
3. pgbouncer (après postgres)
4. jobs : kratos-migrate (après postgres), minio-init (après minio),
   elasticsearch-setup (après elasticsearch — fixe le mdp `kibana_system`)
5. kratos (après migrate), temporal (auto-setup après postgres)
6. oathkeeper, nominatim, kafka-ui, temporal-ui, kibana
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
- **Consoles d'administration** (minio, pgadmin, kafka, temporal, kibana,
  kiali, prometheus, grafana, alertmanager, argo) : restreintes au LAN par le bloc `allow`/`deny`
  des vhosts nginx, et par des enregistrements A publics qui pointent sur une
  IP privée. Deux barrières indépendantes.
- **JWT à l'edge** (optionnel) : Oathkeeper peut minter un JWT signé (mutator
  `id_token`) pour décharger le backend — nécessite JWKS + passage HS256→RS256.
  Laissé désactivé (voir `oathkeeper/configmap.yaml`).

---

## 9. Runbook — remise à plat de la plateforme (prod vide)

`urbanlink.fr` doit rester une **plateforme vide** : schéma + données de
référence seulement (badges, taxonomie), **zéro** utilisateur, annonce,
message ou conversation de démonstration, **zéro** identité Kratos. Ce
runbook est la séquence à suivre pour y ramener un cluster qui porte encore
des données de démo ou de test — outillage : `backend/reset-job.yaml.MANUAL`
(désamorcé exprès, voir son en-tête) + `backend/badges-job.yaml`.

⚠️ Manuel de bout en bout — aucune de ces étapes n'est dans `kustomization.yaml`,
Argo ne les rejoue jamais de lui-même.

### ⚠️ Étape 0 — couper les sessions AVANT de vider la base applicative

**Vider Kratos EN PREMIER, ou mettre le backend à zéro réplique.** L'ordre
inverse laisse une fenêtre pendant laquelle un porteur de session encore
valide touche le backend, ne trouve plus son utilisateur (la table vient
d'être vidée) et le fait **recréer** par `AuthService.getOrCreateUser`.

Ce n'est pas théorique : mesuré en production le 2026-09-06. Entre le vidage
de la base applicative et celui de Kratos — moins d'une minute — un navigateur
resté ouvert a recréé son propre utilisateur, et les deux répliques du backend
ont couru pour le faire, laissant dans les journaux un
`Unique constraint failed on the fields: ("kratosId")` pour seule trace. La
plateforme n'était donc PAS vide à la fin de la séquence, et rien ne le
signalait : il a fallu recompter.

Deux façons de fermer la fenêtre, au choix :

```bash
# a) couper le trafic applicatif le temps de l'opération (le plus sûr)
kubectl -n urbanconnect scale deploy/backend --replicas=0
# … étapes 1 et 2 …
kubectl -n urbanconnect scale deploy/backend --replicas=2

# b) ou simplement inverser : Kratos d'abord (étape 2), base applicative ensuite
```

Dans les deux cas, **recompter les utilisateurs après la séquence complète**,
pas seulement après l'étape 1 :

```bash
kubectl -n urbanconnect exec postgres-0 -- \
  psql -U urbanconnect -d urbanconnect -tAc "SELECT count(*) FROM users;"
```

### Étape 1 — vider la base applicative

```bash
kubectl -n urbanconnect delete job backend-reset-app-db --ignore-not-found
kubectl -n urbanconnect apply -f backend/reset-job.yaml.MANUAL   # les DEUX Jobs — kratos suit à l'étape 2
kubectl -n urbanconnect logs -f job/backend-reset-app-db
```

Livré tel quel (`RESET_CONFIRM` vide), ce Job est un **dry-run** : il imprime
le plan (tables préservées, tables à vider, décompte de lignes) et ne touche
rien. Lire ce plan AVANT de continuer — c'est le moment de repérer une table
qui n'aurait pas dû être vidée, ou une base à laquelle on ne s'attendait pas.

Pour effacer réellement : éditer `RESET_CONFIRM` du Job `backend-reset-app-db`
dans `reset-job.yaml.MANUAL` (nom exact de `POSTGRES_DB`, vérifié plutôt que
supposé — voir le commentaire sur place), supprimer puis réappliquer le Job.

**Vérifier après cette étape :**
```bash
kubectl -n urbanconnect logs job/backend-reset-app-db | tail -20   # décompte APRÈS à 0, tables préservées inchangées
```
`badges` (1331 définitions), la taxonomie (`main_types`/`categories`/
`subcategories`/`specialties`) et `_prisma_migrations` doivent apparaître
inchangés dans le rapport ; toutes les autres tables à 0.

### Étape 2 — vider les identités Kratos

Même Job manifeste (`backend-reset-kratos`, déjà appliqué à l'étape 1 —
même fichier) — mais c'est une base et une porte `RESET_CONFIRM`
**complètement séparées** de l'étape 1 (voir l'en-tête de
`reset-job.yaml.MANUAL` : pourquoi deux Jobs plutôt qu'un seul).

```bash
kubectl -n urbanconnect logs -f job/backend-reset-kratos
```

Même logique dry-run par défaut ; éditer `RESET_CONFIRM` de CE Job
(nom exact de la base Kratos — `KRATOS_DB_NAME`, `kratos` par défaut),
supprimer puis réappliquer pour effacer réellement.

**Vérifier après cette étape :**
```bash
kubectl -n urbanconnect exec deploy/kratos -- curl -s http://localhost:4434/admin/identities
```
Doit rendre `[]`. Toute réponse non vide signifie que l'étape n'a pas
(encore) été confirmée, ou a porté sur la mauvaise base.

### Étape 3 — rejouer les badges

Les badges ne sont PAS détruits par l'étape 1 (`badges` est dans sa liste de
préservation) — cette étape est une vérification de sûreté, pas un
rattrapage : elle garantit que le catalogue est bien à jour avec le code
actuellement déployé (upsert idempotent, sans effet si rien n'a changé),
plutôt que de supposer que « préservé » veut dire « à jour ».

```bash
kubectl -n urbanconnect delete job backend-badges --ignore-not-found
kubectl -n urbanconnect apply -f backend/badges-job.yaml
kubectl -n urbanconnect logs -f job/backend-badges
```

**Vérifier après cette étape :** le Job se termine en `Completed`, et
`SELECT count(*) FROM badges;` (via `kubectl exec` sur le pod postgres) rend
1331 (ou la valeur courante du catalogue si `badges.seed.ts` a changé depuis).

### Après les trois étapes

- Le back-office (`adminSearchUsers`) ne doit plus rendre aucun compte.
- `POST /graphql` doit continuer à répondre (une base vide n'est pas censée
  empêcher le boot — vérifié en dev, voir le rapport de livraison de ce
  chantier) : `curl -s -X POST https://api.urbanlink.fr/graphql -H 'Content-Type: application/json' -d '{"query":"{ __typename }"}'`.
- **MinIO n'a pas été touché** : les images déjà envoyées (avatars, photos
  d'annonces, CV) restent dans le bucket, orphelines. Purge hors périmètre de
  ce runbook — voir l'en-tête de `reset-job.yaml.MANUAL` et celui de
  `backend-seed` pour la méthode (comparer les clés référencées en base — donc
  disponibles seulement AVANT l'étape 1 — à `mc ls --recursive`) si une purge
  est un jour décidée.
