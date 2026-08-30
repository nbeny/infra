# Manifests Kubernetes

Charges applicatives déployées sur les clusters du lab. Un sous-dossier par
application.

| Dossier | Application | Cluster cible |
|---|---|---|
| [`urbanlink/`](urbanlink/) | Stack UrbanConnect / UrbanLink — 27 composants | VM `urbanlink` (10.0.0.111) |

---

## `urbanlink/`

### Provenance

Copie de `UrbanConnct/kube/` (dépôt applicatif), **sans modification des
manifests**. Ce dépôt-ci fournit ce qui manquait pour qu'ils démarrent :
une StorageClass, les CRD Traefik et CrowdSec.

Deux ajouts propres à ce dépôt, absents de l'amont :

| Chemin | Rôle |
|---|---|
| `_config/kratos/` | Config Kratos et schéma d'identité — source de la ConfigMap `kratos-config` |
| `_config/postgres-init/` | `init-db.sql` et `create-databases.sh` — source de la ConfigMap `postgres-init` |
| `_build/Dockerfile.temporal-worker` | Le worker Temporal n'a pas de Dockerfile en amont (compose monte les sources) |

`_config/kratos/.google-oidc.env` n'a **pas** été copié : il contient de vrais
identifiants OAuth. Les `client_secret` des fichiers présents sont des
placeholders `GOCSPX-REPLACE_ME`, et `secrets.yaml` ne contient que des
`CHANGE_ME` — rien de sensible n'est versionné ici.

### Resynchroniser depuis l'amont

```bash
cp -r C:/Users/nbeny/Documents/GitHub/UrbanConnct/kube/. kube/urbanlink/
```

Écrase les manifests, préserve `_config/` et `_build/`. Vérifie ensuite que
`secrets.yaml` ne contient toujours que des `CHANGE_ME`.

---

### Ce que le lab fournit

Un cluster kubeadm nu ne suffit pas pour ces manifests. Trois manques, tous
comblés automatiquement par `ansible/playbooks/20-debian-k8s.yml` :

| Manque | Conséquence sans lui | Comblé par |
|---|---|---|
| Aucun provisionneur de volumes | Les 9 PVC restent `Pending`, aucun StatefulSet ne démarre | `local-path-provisioner`, StorageClass par défaut |
| Pas d'ingress ni de CRD associées | `kubectl apply -k` échoue en bloc | **Istio** (Gateway + VirtualService) |
| Réseau de pods plat, aucun chiffrement | Le frontend peut joindre PostgreSQL en direct | **Istio ambient** : mTLS automatique + `AuthorizationPolicy` |

Réglages dans `ansible/inventory/group_vars/debian_nodes.yml` et
`ansible/inventory/host_vars/urbanlink.yml`.

---

### Istio remplace Traefik

L'ingress est passé de Traefik à Istio. La correspondance :

| Traefik | Istio |
|---|---|
| `IngressRoute` (routage + politique mêlés) | `VirtualService` — routage seul |
| `Middleware` `uc-edge` / `uc-edge-auth` | `AuthorizationPolicy` — politique seule |
| `entryPoints` + `TLSOption uc-tls` | `Gateway` (`minProtocolVersion: TLSV1_2`) |
| `forwardAuth` vers Oathkeeper | `AuthorizationPolicy` action `CUSTOM` + ext_authz |
| `certResolver: letsencrypt` (ACME natif) | Secret TLS — **cert-manager requis en production** |
| plugin bouncer CrowdSec | *rien* — voir ci-dessous |

Les manifests Traefik ont été supprimés : ils n'étaient plus appliqués depuis
la bascule, et leurs CRD ne sont même plus installées sur le cluster — les
garder ne documentait plus rien qu'on puisse relire utilement. Le tableau
ci-dessus conserve la correspondance, c'est ce qui avait de la valeur.
`ingress/` contient désormais les manifests Istio.

**Mode ambient, et ce n'est pas un choix de confort.** Le mode sidecar injecte
un conteneur dans chaque pod, ce qui casse deux choses dans ce stack : les
trois Jobs (`kratos-migrate`, `minio-init`, `elasticsearch-setup`) ne se
termineraient jamais — le conteneur applicatif sort, le sidecar reste vivant —
et `coturn` tourne en `hostNetwork`, où un sidecar n'intercepte rien. En
ambient, l'interception se fait par un `ztunnel` par nœud : aucun de ces deux
problèmes, et l'enrôlement se fait par un label de namespace sans redémarrer
un seul pod.

#### Deux régressions assumées

**CrowdSec disparaît du cluster.** Son bouncer était un plugin Go du binaire
Traefik. Le portage Envoy officiel (`crowdsecurity/cs-envoy-bouncer`) n'a ni
release ni image publiée, et brancher l'AppSec en direct est impossible : elle
exige l'URI et l'IP client de chaque requête dans des en-têtes
`X-Crowdsec-Appsec-*`, or le champ Istio `includeAdditionalHeadersInCheck`
n'accepte que des valeurs **fixes**. CrowdSec reste donc actif sur le nginx du
nœud Proxmox, qui est de toute façon la vraie porte d'entrée Internet.
Ce qui est réellement perdu devant l'API : le WAF applicatif (SQLi/XSS,
virtual patching des CVE) et la blocklist communautaire d'IP.

**Le TLS n'est plus automatique.** Traefik obtenait ses certificats seul.
Istio lit un Secret. Dans le lab, le playbook dépose un certificat auto-signé
— suffisant pour valider le routage, pas pour des visiteurs. En production :

```bash
helm install cert-manager jetstack/cert-manager -n cert-manager --create-namespace --set crds.enabled=true
# puis un Certificate qui remplit le secret uc-tls-cert dans istio-ingress
```

Le challenge DNS-01 via Cloudflare est le plus robuste ici — il ne dépend
d'aucune joignabilité HTTP (voir `docs/audit-securite.md`, constat 3).

#### Vérifié après bascule

```console
$ curl -H 'Host: pgadmin.urbanconnect.fr' http://10.0.0.111:30080/     → 302
$ curl -H 'Host: inconnu.example.com'     http://10.0.0.111:30080/     → 404
$ curl -H 'Host: api.urbanconnect.fr'     http://10.0.0.111:30080/metrics → 404
$ curl -H 'Host: api.urbanconnect.fr'     http://10.0.0.111:30080/graphql → 403
```

Le 404 sur `/metrics` reproduit le `!PathPrefix` de Traefik ; le 403 sur
`/graphql` montre l'ext_authz actif et **fail-closed** (`failOpen: false` —
une panne d'Oathkeeper refuse les requêtes au lieu de les laisser passer).

#### Piste d'amélioration relevée par `istioctl analyze`

Six Services nomment leurs ports sans préfixe de protocole (`postgres`,
`redis`, `pgbouncer`, `pgadmin`, `postgres-nominatim`, `temporal-ui`). Istio
retombe alors sur la détection automatique. Les nommer `tcp-postgres`,
`http-web`… rend le traitement déterministe :

```bash
istioctl analyze -n urbanconnect
```

---

### Déployer

Le cluster doit exister — voir le README racine. Ensuite :

```bash
ssh root@192.168.100.50
cd /root/infra
```

**1. Construire les 3 images applicatives.** Elles ne sont dans aucun
registre : l'amont ne fournit que des Dockerfiles.

```bash
# Depuis Windows — déposer les sources sur le nœud
cd C:/Users/nbeny/Documents/GitHub/UrbanConnct
tar -czf - --exclude=node_modules --exclude=.next --exclude=dist \
           --exclude=.git --exclude=coverage backTs front \
  | ssh root@192.168.100.50 'mkdir -p /root/urbanlink-src && tar -xzf - -C /root/urbanlink-src'

# Sur le nœud
cd /root/infra/ansible
ansible-playbook playbooks/30-urbanlink-images.yml
```

Compte 15 à 30 min, dominées par les deux `npm install`.

> Le playbook réimporte les images dans containerd (`ctr -n k8s.io images
> import`). Sans ça, kubelet ne les verrait pas : `docker build` écrit dans le
> magasin de Docker, kubelet interroge le namespace `k8s.io` de containerd.
> Les deux ne communiquent pas.

> **Le backend ne se construit pas en l'état.** `backTs/package-lock.json` a
> divergé de `package.json` et le Dockerfile utilise `npm ci`, qui refuse ce
> cas — à raison. La correction est dans le dépôt applicatif (`npm install`
> dans `backTs/` puis commit du lockfile). Pour débloquer un test sans y
> toucher : `-e urbanlink_backend_relock=true`, qui régénère le lockfile dans
> la copie de build uniquement. Voir `docs/audit-securite.md`, constat B1.

**2. Déployer le stack.**

```bash
ansible-playbook playbooks/31-urbanlink-deploy.yml
```

Le playbook vérifie les prérequis (cluster sain, StorageClass par défaut, CRD
Traefik), crée le namespace et les deux ConfigMaps (`kratos-config`,
`postgres-init`), applique le kustomize, puis rapporte l'état des pods et des
PVC.

```bash
# repartir de zéro (supprime le namespace et tout son contenu)
ansible-playbook playbooks/31-urbanlink-deploy.yml -e urbanlink_wipe=true
```

L'ordre de démarrage recommandé est décrit en tête de `kustomization.yaml`.
Kubernetes converge seul grâce aux redémarrages : plusieurs pods bouclent en
`CrashLoopBackOff` quelques minutes avant que leurs bases soient prêtes, c'est
normal. Ce qui boucle encore après ~10 min mérite un `kubectl logs`.

---

### Résultat du déploiement réel

Déployé et observé sur la VM `urbanlink` le 30 août 2026. `kubectl apply -k` a
créé **62 objets**, 8 PVC sur 9 provisionnés, 28 pods.

| État | Pods |
|---|---|
| ✅ `Running` (16) | postgres, postgres-nominatim, pgbouncer ×2, redis, kafka, kafka-ui, elasticsearch, elasticsearch-setup, kibana, nominatim, directus, pgadmin, coturn, kratos-migrate, **temporal-worker** |
| ✅ `Completed` (1) | minio-init |
| ❌ `CrashLoopBackOff` (9) | backend ×2, kratos ×2, minio, oathkeeper ×2, temporal-ui, temporal |
| ⏸ `Pending` (2) | frontend ×2 |

**Toute la couche infrastructure monte.** Bases, cache, brokers, recherche,
géocodage, CMS, outils d'admin : tout tourne. La chaîne
image cloud → Packer → Terraform → Ansible → `apply -k` fonctionne de bout en
bout.

Les échecs restants ne viennent pas de l'infrastructure. Chacun a une cause
identifiée :

| Pod | Cause exacte | Où corriger |
|---|---|---|
| `minio` | `exec: "server": executable file not found in $PATH` — le manifeste utilise `command: ["server", ...]`, ce qui **remplace** l'ENTRYPOINT de l'image au lieu de lui passer des arguments. Il faut `args:` (ou `command: ["minio"]` + `args: ["server", ...]`). | Manifeste `minio/statefulset.yaml` — échouerait partout, pas seulement ici |
| `temporal-ui` | `cannot unmarshal !!str 'tcp://1...' into int` — le Service s'appelle `temporal-ui`, donc Kubernetes injecte automatiquement `TEMPORAL_UI_PORT=tcp://10.x.x.x:8080`, qui écrase la variable que l'application attend comme entier. | Ajouter `enableServiceLinks: false` au pod, ou renommer le Service |
| `oathkeeper` | `errors/handlers/redirect/config/when[0].error` : des entiers là où le schéma attend des chaînes, et `enabled` doit valoir `false`. | ConfigMap `oathkeeper/configmap.yaml` |
| `kratos` | `secrets/cipher/0 : length must be >= 32, but got 31` — le **placeholder lui-même** (`CHANGE_ME_32_CHARS…`) fait 31 caractères. | `secrets.yaml`, au moment de le remplir |
| `backend` | `The datasource.url property is required in your Prisma config file when using prisma migrate deploy` — la variable `DATABASE_URL` est pourtant bien câblée depuis le Secret (vérifié). Prisma récent attend l'URL déclarée dans `prisma.config.ts`. | Dépôt applicatif, configuration Prisma |
| `temporal` | Dépend de `postgres` + des schémas créés par `auto-setup` ; repart quand ses dépendances sont prêtes. | Convergence, pas un défaut |
| `frontend` | Bloqué sur le PVC `geoip-data`, en `ReadWriteMany`. `local-path` est un stockage **local**, il ne provisionne pas de RWX. | Limite du lab — voir ci-dessous |

Rien de tout cela ne se répare en changeant l'infrastructure : ce sont des
défauts de manifestes et de configuration applicative, que le déploiement a
justement permis de révéler.

### Limites connues dans ce lab

Ces points ne sont pas des défauts du stack : ce sont des écarts entre un lab
NATé et l'environnement de production visé.

| Point | Détail |
|---|---|
| **TLS / ACME** | Les `IngressRoute` visent `*.urbanconnect.fr`. Aucun DNS public ne pointe ici, donc Let's Encrypt ne peut pas valider : les certificats resteront auto-signés. Sans effet sur le démarrage des pods. |
| **`geoip-data`** | PVC en `ReadWriteMany`. `local-path` est un stockage local : le mode est accepté sur un nœud unique, mais ne tiendrait pas sur un cluster multi-nœuds. |
| **Nominatim** | Le pod démarre, mais l'import des données OSM (plusieurs heures, ~200 Gio) n'est pas déclenché. Le géocodage répondra vide tant qu'il n'a pas tourné. |
| **Secrets** | `secrets.yaml` contient des `CHANGE_ME`. Les composants démarrent, mais tout ce qui dépend d'un vrai identifiant externe (Stripe, Google OIDC, MaxMind) ne fonctionnera pas. |
| **Volumétrie** | ~548 Gio de PVC réclamés au total. `local-path` provisionne à la demande sans réserver, donc l'usage réel reste très inférieur tant que les données ne sont pas là. |

---

### Accès

La passerelle Istio est exposée en NodePort sur la VM (pas de LoadBalancer en
bare-metal) — elle a repris les ports que Traefik occupait :

```bash
# Tunnel depuis Windows
ssh -L 8080:10.0.0.111:30080 -L 8443:10.0.0.111:30443 pve
```

Les `IngressRoute` filtrent sur le nom d'hôte : il faut donc présenter le bon
`Host`. Soit via `/etc/hosts` (`127.0.0.1 urbanconnect.fr api.urbanconnect.fr`),
soit directement :

```bash
curl -H 'Host: api.urbanconnect.fr' http://localhost:8080/
```

**Kiali** — le graphe de service du mesh : qui parle à qui, en mTLS ou non,
avec les taux d'erreur. C'est l'outil qui remplace avantageusement le dashboard
Traefik pour comprendre ce qui se passe dans le cluster.

```bash
kubectl -n istio-system port-forward svc/kiali 20001:20001
# puis http://localhost:20001
```

Diagnostic du maillage :

```bash
istioctl analyze -A                          # cohérence de la configuration
istioctl ztunnel-config workload             # charges réellement capturées
kubectl -n istio-system logs ds/ztunnel      # trafic mTLS, identités SPIFFE
```
