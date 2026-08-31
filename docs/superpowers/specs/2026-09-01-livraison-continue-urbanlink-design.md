# Livraison continue UrbanLink — design

**Date** : 2026-09-01
**Dépôts concernés** : `nbeny/UrbanConnct` (applicatif), `nbeny/infra` (celui-ci)

---

## 1. Le problème

Un `git push` sur `main` du dépôt applicatif doit suffire à mettre le cluster à
jour : images reconstruites, variables de configuration propagées, pods
redémarrés. Aujourd'hui aucune des trois ne se fait toute seule.

### Ce qui existe déjà, et qui marche

`UrbanConnct/.github/workflows/ci.yml` porte deux jobs pertinents, écrits mais
**jamais menés à terme** — `kube/urbanlink/kustomization.yaml` n'a aucune
section `images:`, et aucun commit `deploy: images` n'existe dans ce dépôt :

- job `images` (l.327) — construit les trois images, les pousse sur GHCR sous
  le tag `sha-<short>`, derrière les quatre portes `backend` / `frontend` /
  `secrets-scan` / `rules-hygiene`.
- job `deploy` (l.428) — `kustomize edit set image` dans `nbeny/infra`, commit
  et push avec rebase.

L'idée est juste : la CI n'écrit que dans git, Argo CD déploie. Elle est
conservée telle quelle. Ce sont ses hypothèses matérielles qui tombent.

### Les quatre défauts à corriger

1. **GHCR privé n'est pas tenable.** Le plan Free plafonne à 500 Mo de stockage
   et 1 Go/mois de transfert. Les trois images sont des images Node ; le quota
   saute au premier build, sans même compter le `cache-to: mode=max` du
   workflow actuel qui pousse toutes les couches intermédiaires. GHCR public
   serait gratuit et illimité, mais publierait l'application compilée.
2. **Les variables ne suivent pas.** Les cinq ConfigMaps sont construites à la
   main par `31-urbanlink-deploy.yml:188`, depuis `config/` du dépôt
   applicatif. Argo ne peut pas les reprendre : chacune fusionne
   `common/<x>` + `prod/<x>`, ce que kustomize ne sait pas faire, et la source
   vit dans un autre dépôt. Un changement dans `config/` laisse Argo afficher
   « Synced » sans rien faire.
3. **Rien ne redémarre les pods** quand une ConfigMap change, même appliquée.
4. **Les Jobs vont casser la synchronisation.** `kustomize edit set image`
   réécrit aussi `backend/migrate-job.yaml:62` : la spec du Job change donc à
   chaque livraison, et `kubectl apply` sur un Job existant échoue en « field
   is immutable ». C'est pourquoi `31-urbanlink-deploy.yml:478` les supprime
   d'abord. `Replace=false` + `ApplyOutOfSyncOnly=true` ne sauvent pas : le Job
   sera hors-sync, donc appliqué, donc en échec.

---

## 2. Contraintes matérielles relevées

| Fait | Source | Conséquence |
|---|---|---|
| Le runner tourne sur une VM `ci-runner`, pas sur `urbanlink` | confirmé par l'utilisateur | les deux containerd sont distincts : un `ctr import` local est inutile, il faut une registry |
| `ci-runner` n'est déclarée **nulle part** dans ce dépôt | absente de `terraform.tfvars.example`, de `inventory/00-static.yml` et des rôles | à déclarer avant de lui appliquer quoi que ce soit |
| Le cluster est mono-nœud | `inventory/host_vars/urbanlink.yml:9` | une seule adresse à qui parler côté pull |
| Les runners self-hosted ne consomment aucune minute Actions | tarification GitHub | la CI elle-même ne coûte rien |
| `urbanlink` = `10.0.0.111` | `inventory/host_vars/urbanlink.yml:8` | |

---

## 3. Décisions

| Décision | Retenue | Pourquoi |
|---|---|---|
| Transport des images | Registry `registry:2` sur `ci-runner`, en conteneur systemd, hors Kubernetes | gratuit, sans quota, sans trafic sortant ; hors du cluster, donc survit à une reconstruction de celui-ci |
| Propagation de `config/` | La CI copie les fichiers dans `infra`, un `configMapGenerator` les monte | un seul mécanisme pour les images et les variables, et le suffixe de hash déclenche le redémarrage des pods |
| Élagage Argo | `prune: true` | sans lui les ConfigMaps hashées s'empilent indéfiniment |
| Jobs immuables | Hooks Argo `PreSync` + `hook-delete-policy: BeforeHookCreation` | reproduit le `kubectl delete` d'Ansible 31, et place la migration avant le rollout |
| Rétention du registre | Purge en fin de job CI, 10 tags par image | le job et la registry sont sur la même VM : aucun SSH, aucun timer, aucun composant de plus |

### Le couplage à `ci-runner`, mesuré et non supposé

Héberger la registry sur la VM de CI fait dépendre `urbanlink` d'elle. Cette
dépendance est **plus faible qu'il n'y paraît** et c'est ce qui rend le choix
tenable : le tag n'étant pas `latest`, `imagePullPolicy` vaut `IfNotPresent`.
Une image tirée reste dans le containerd d'`urbanlink` ; un redémarrage de pod,
un reboot du nœud, un rescheduling ne provoquent **aucun pull**. La registry
n'est sollicitée que pour un tag *nouveau* — donc pendant une livraison, donc
quand `ci-runner` tourne par construction.

Deux cas d'exposition subsistent, tous deux à connaître :

- **Le nœud est reconstruit.** Plus aucune image locale : `ci-runner` doit être
  debout pour que le stack redémarre.
- **Pression disque.** Au-delà du seuil haut de kubelet (85 % par défaut), les
  images non référencées sont évincées. Sur 700 Go c'est lointain, mais ce
  n'est pas nul.

---

## 4. Architecture cible

```
push sur main de UrbanConnct
   │
   ├─ backend · frontend · secrets-scan · rules-hygiene      [portes existantes]
   │
   ├─ job « images »              sur ci-runner
   │     docker build ×3                    (cache de couches local, gratuit)
   │     docker push  →  <ci-runner>:5000/urbanconnect-*:sha-abc1234
   │     purge des tags au-delà des 10 derniers + garbage-collect
   │
   └─ job « deploy »              sur ci-runner        needs: images
         checkout de nbeny/infra  (INFRA_DEPLOY_KEY)
         kustomize edit set image ×3
         rsync  config/{common,prod}  →  kube/urbanlink/config/
         garde : échoue si un fichier de config n'est pas déclaré
         commit + push (rebase ×3)
               │
               ▼
         Argo CD — automated, selfHeal, prune
               │
               ├─ hooks PreSync : backend-migrate, kratos-migrate, kibana-setup
               ├─ configMapGenerator → kratos-config-7f3d9k (nom = hash du contenu)
               └─ Deployments réécrits → pods redémarrés
                        │
                        └─ kubelet pull  ←  <ci-runner>:5000   (tag neuf uniquement)
```

L'ordre est garanti par `needs: images` : l'image est dans la registry avant
qu'Argo n'en voie le tag. Sans cette contrainte les pods partiraient en
`ImagePullBackOff` le temps du build.

**La CI ne lance aucun `kubectl` sur les charges de travail.** Elle écrit un tag
et des fichiers dans git ; tout le déploiement est le fait d'Argo.

---

## 5. Composants

### 5.1 Déclarer `ci-runner` — dépôt `infra`

`ansible/inventory/00-static.yml` gagne un groupe `ci_nodes` sous `guests`,
avec l'hôte `ci-runner` et son adresse. Un groupe **distinct** de
`debian_nodes` : ce dernier reçoit le rôle `kubernetes` par `site.yml`, or
cette VM n'a pas à porter de cluster.

`ansible/inventory/group_vars/ci_nodes.yml` — docker seul, avec l'utilisateur
du service runner dans `docker_users`.

⚠️ **Valeurs à relever sur la machine avant d'écrire quoi que ce soit** :
l'adresse IP, l'utilisateur sous lequel tourne le service runner, et la taille
du disque. Aucune n'est déductible du dépôt.

### 5.2 Rôle `registry` — dépôt `infra`

`ansible/roles/registry/` + `ansible/playbooks/35-ci-registry.yml`, joué sur
`ci_nodes`.

- Conteneur `registry:2`, redémarrage automatique, volume `/var/lib/registry`.
- `REGISTRY_STORAGE_DELETE_ENABLED=true` — sans lui l'API refuse les
  suppressions de manifeste et la purge du § 5.3 est un no-op silencieux.
- Écoute liée à l'adresse de LAN, pas à `0.0.0.0`.
- HTTP, sans authentification. Le LAN `10.0.0.0/24` est interne au lab ; c'est
  une limite assumée, consignée au § 8.

Côté `urbanlink`, containerd doit accepter un registre en clair :

- `/etc/containerd/certs.d/<ci-runner>:5000/hosts.toml` avec
  `capabilities = ["pull", "resolve"]` et `skip_verify`.
- ⚠️ Ce répertoire n'est lu que si `config_path = "/etc/containerd/certs.d"`
  figure sous `[plugins."io.containerd.grpc.v1.cri".registry]` de
  `/etc/containerd/config.toml`. Or ce fichier est produit par
  `containerd config default` (`roles/docker/tasks/main.yml:82`), qui laisse
  `config_path` **vide**. Sans cette ligne, le `hosts.toml` est ignoré sans un
  mot et le pull échoue sur une erreur TLS qui n'évoque rien du problème.
- containerd relit ce réglage au démarrage : un redémarrage du service est
  nécessaire.

Ces deux tâches vont dans le rôle `docker`, derrière une variable
`docker_insecure_registries` par défaut vide — c'est lui qui possède déjà la
configuration containerd, et la dupliquer ailleurs créerait deux endroits où
elle peut diverger.

### 5.3 Job `images` — dépôt `UrbanConnct`

Remplace `docker/build-push-action` :

- `docker build` local, un tag `<ci-runner>:5000/urbanconnect-*:sha-<short>`.
  Le runner étant persistant, le cache de couches Docker survit d'un build à
  l'autre : plus rapide que le cache de registre, et gratuit.
- `docker push` — seules les couches modifiées traversent le réseau.
- Les `build-args` du frontend sont conservés à l'identique. Ils sont gravés
  dans le bundle Next.js au build et ne sont pas relisables à l'exécution.
- Dernière étape, en local : lister les tags via `/v2/<image>/tags/list`,
  garder les 10 plus récents, supprimer le reste par digest, puis
  `registry garbage-collect`.

⚠️ Le `cache-from` / `cache-to` de registre est **retiré**, pas déplacé : c'est
lui qui aurait fait exploser n'importe quel quota, et le cache local du runner
le remplace avantageusement.

### 5.4 Job `deploy` — dépôt `UrbanConnct`

Conserve `kustomize edit set image` et la boucle de push avec rebase. S'y
ajoute, avant le commit :

- `rsync --delete` de `config/common` et `config/prod` vers
  `infra/kube/urbanlink/config/`. Le `--delete` importe : sans lui un fichier
  supprimé côté applicatif survivrait indéfiniment dans `infra`.
- **La garde.** Échoue si un fichier de premier niveau d'un répertoire
  consommé par une ConfigMap n'apparaît pas dans le `configMapGenerator`
  (exceptions : `README.md`, `CLAUDE.md`). Sans elle, ajouter un fichier à
  `config/common/kratos/` le laisserait silencieusement hors du cluster.

### 5.5 `configMapGenerator` — dépôt `infra`

`kube/urbanlink/kustomization.yaml` :

```yaml
configMapGenerator:
  - name: kratos-config
    files: [config/common/kratos/identity.schema.json,
            config/common/kratos/oidc.google.jsonnet,
            config/prod/kratos/kratos.yml]
  - name: postgres-init
    files: [config/common/postgres-init/create-databases.sh,
            config/common/postgres-init/init-db.sql]
  - name: pgbouncer-config
    envs:  [config/prod/pgbouncer/pgbouncer.env]
  - name: nominatim-config
    envs:  [config/prod/nominatim/nominatim.env]
  - name: kibana-dashboards
    files: [config/common/kibana/dashboards.ndjson]
```

`envs:` et non `files:` pour les deux fichiers d'environnement : ils sont
consommés par `envFrom: configMapRef:`, qui attend une ConfigMap dont chaque
clé est une variable. `files:` produirait une clé unique nommée comme le
fichier, et le pod échouerait sur une variable absente alors qu'elle figure
bien dedans — le piège déjà documenté en `31-urbanlink-deploy.yml:214`.

Liste explicite, car kustomize n'accepte pas de répertoire. Deux écarts par
rapport à ce que produit Ansible 31, tous deux sans effet fonctionnel :

- `CLAUDE.md` n'entre plus dans `kratos-config`. Il y était par accident,
  `--from-file=<répertoire>` prenant tout ce qu'il trouve.
- Les sous-répertoires `common/kratos/{email,email-templates,scripts}` restent
  exclus. Ils l'étaient déjà : `--from-file` ne récurse pas.

Le suffixe de hash fait que le nom change dès que le contenu change ; kustomize
réécrit toutes les références dans le même build, donc les Deployments et les
Jobs pointent sur le nouveau nom et les pods redémarrent. C'est le mécanisme
qui répond au défaut n° 3.

⚠️ Effet à accepter : un changement dans `postgres-init` redémarre Postgres, un
changement dans `nominatim.env` redémarre Nominatim (33 Go d'OSM importés, PVC
conservé, mais long). C'est le comportement correct — ces pods lisent leur
configuration au démarrage et rien d'autre — mais il faut le savoir avant de
toucher à ces deux fichiers.

### 5.6 Les trois Jobs deviennent des hooks

`backend/migrate-job.yaml`, `kratos/migrate-job.yaml`, `kibana/setup-job.yaml` :

```yaml
annotations:
  argocd.argoproj.io/hook: PreSync
  argocd.argoproj.io/hook-delete-policy: BeforeHookCreation
```

`PreSync` place la migration **avant** le rollout du backend, un ordre
qu'aucun mécanisme ne garantissait jusqu'ici.

`minio-init` et `elasticsearch-setup` restent des ressources ordinaires : ni
leur image ni leur configuration ne bougent, donc ils ne repassent jamais
hors-sync.

### 5.7 Ansible allégé — dépôt `infra`

- `31-urbanlink-deploy.yml` — la section « Creer les ConfigMaps prerequises »
  (l.188-266) est retirée : Argo les possède désormais, et les laisser créerait
  des doublons non hashés que personne ne lit. Le playbook se réduit à
  l'amorçage : Secret, `AuthorizationPolicy`, certificat de passerelle,
  namespace.
- `32-argocd.yml` — `prune: true` dans la `syncPolicy`, et l'en-tête réécrit :
  la liste « ce qu'Argo CD ne peut PAS reprendre » perd son point 1.
- `30-urbanlink-images.yml` — conservé comme chemin d'amorçage manuel (premier
  démarrage, cluster reconstruit hors CI), avec un en-tête disant que la CI le
  supplante en régime normal.

---

## 6. Ce qui reste manuel, et pourquoi

- **Le Secret `urbanconnect-secrets`.** Construit depuis un `secrets.env` non
  versionné. Une CI qui le lirait dans git supposerait qu'il y soit — ce qu'on
  refuse.
- **⚠️ Couplage à connaître.** `KRATOS_OIDC_PROVIDERS` du Secret est *dérivé*
  de `config/prod/kratos/kratos.yml` (`31-urbanlink-deploy.yml:361-378`) :
  Ansible lit la structure `providers` du fichier et y injecte les vrais
  identifiants Google. Changer les fournisseurs OIDC dans ce fichier propage la
  ConfigMap automatiquement mais **pas** le Secret. Il faut rejouer 31. À
  documenter en tête de `config/prod/kratos/kratos.yml` et de la section Secret
  du playbook, sans quoi la panne serait muette : Kratos démarre, et seule la
  connexion Google échoue.
- **L'`AuthorizationPolicy`** d'`istio-ingress`, hors du namespace forcé par le
  kustomization.
- **L'edge nginx du nœud PVE** (`33-urbanlink-edge.yml`) — hors périmètre,
  il ne bouge pas.

---

## 7. Bascule

Ordre imposé : chaque étape suppose la précédente.

1. Relever sur `ci-runner` : adresse IP, utilisateur du service runner, disque
   disponible. Les déclarer dans l'inventaire (§ 5.1).
2. Jouer `35-ci-registry.yml` — la registry tourne, `curl /v2/` répond `200`.
3. Jouer le rôle `docker` sur `urbanlink` avec `docker_insecure_registries` —
   containerd redémarré, `crictl pull` d'une image de test réussit **depuis
   `urbanlink`**. C'est la vérification qui compte : elle valide à la fois la
   route réseau, le `hosts.toml` et le `config_path`.
4. Écrire le `configMapGenerator` et les annotations de hook dans `infra`,
   déposer une première copie de `config/` à la main, pousser sur `master`.
5. Vérifier qu'Argo synchronise sans erreur **avant** de toucher à `prune`.
6. Poser `prune: true`.
7. Supprimer les cinq ConfigMaps non hashées héritées d'Ansible 31. Argo ne les
   a pas créées : `prune` ne les touchera jamais.
8. Modifier `ci.yml` dans le dépôt applicatif, pousser sur `main`, observer la
   chaîne complète.

L'étape 5 avant l'étape 6 n'est pas une précaution de confort : `prune` sur une
Application dont la synchro échoue peut supprimer ce qu'elle n'arrive pas à
recréer.

---

## 8. Limites assumées

- **Registre en HTTP sans authentification** sur le LAN interne. N'importe
  quelle machine du `10.0.0.0/24` peut y pousser. Ajouter un `htpasswd` et un
  `imagePullSecret` est un incrément indépendant, à faire le jour où le LAN
  cesse d'être de confiance.
- **`urbanlink` dépend de `ci-runner`** pour tirer un tag neuf. Portée réelle
  et cas d'exposition détaillés au § 3.
- **Mono-nœud.** Rien ici n'en dépend — c'est la registry qui rend le design
  indifférent au nombre de nœuds — mais le `hosts.toml` devra être posé sur
  chaque nœud ajouté.
- **`ci-runner` reste hors Terraform.** On la déclare dans l'inventaire Ansible
  pour pouvoir la configurer, sans la reprendre sous Terraform : ce serait un
  chantier distinct, et le faire ici mêlerait deux sujets.

---

## 9. Vérification

Ce qui prouve que la chaîne fonctionne, dans l'ordre où le vérifier :

| Quoi | Comment |
|---|---|
| Le registre reçoit | `curl <ci-runner>:5000/v2/urbanconnect-backend/tags/list` |
| `urbanlink` tire | `crictl pull <ci-runner>:5000/urbanconnect-backend:<tag>` depuis la VM |
| Le bump atterrit | un commit `deploy: images sha-…` dans `infra` |
| Argo réagit | `kubectl -n argocd get application urbanlink -o jsonpath='{.status.sync.status}/{.status.health.status}'` → `Synced/Healthy` |
| Les pods portent la bonne image | `kubectl -n urbanconnect get deploy backend -o jsonpath='{..image}'` |
| Une variable se propage | modifier `config/prod/pgbouncer/pgbouncer.env`, pousser, vérifier que le nom de la ConfigMap montée par pgbouncer a changé |
| La purge borne le registre | après 11 livraisons, `tags/list` en renvoie 10 |
