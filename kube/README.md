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
| CRD `IngressRoute` / `Middleware` / `TLSOption` absentes | `kubectl apply -k` échoue en bloc | Traefik (chart Helm) |
| Pas de LAPI ni de WAF CrowdSec | Les `Middleware` `crowdsec` et `uc-edge` ne résolvent pas | CrowdSec (chart Helm) + plugin bouncer déclaré dans Traefik |

Réglages dans `ansible/inventory/group_vars/debian_nodes.yml`
(`k8s_storage_provisioner`, `k8s_ingress_controller`, `k8s_crowdsec_enabled`).

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

Traefik est exposé en NodePort sur la VM (pas de LoadBalancer en bare-metal) :

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

Dashboard Traefik (non exposé, volontairement) :

```bash
kubectl -n traefik port-forward deploy/traefik 9000:9000
```
