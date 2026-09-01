# Livraison continue UrbanLink — plan d'implémentation

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Un `git push` sur `main` du dépôt applicatif reconstruit les images, propage les variables de `config/` et redémarre les pods concernés, sans aucune intervention.

**Architecture:** La CI (runner self-hosted sur la VM `ci-runner`) construit les images et les pousse dans une registry `registry:2` locale à cette même VM, puis écrit deux choses dans le dépôt `nbeny/infra` : le tag des images et une copie de `config/`. Argo CD, qui suit `master`, fait tout le déploiement. Aucun `kubectl` sur les charges de travail n'est lancé par la CI.

**Tech Stack:** GitHub Actions (runner self-hosted), Docker, `registry:2`, containerd, Ansible, Kustomize (`configMapGenerator`), Argo CD.

**Spec de référence:** `docs/superpowers/specs/2026-09-01-livraison-continue-urbanlink-design.md`

---

## Avant de commencer

**Deux dépôts sont touchés :**

| Dépôt | Chemin local | Tâches |
|---|---|---|
| `nbeny/infra` | `C:/Users/nbeny/Documents/GitHub/infra` | 1 → 7, 11, 12 |
| `nbeny/UrbanConnct` | `C:/Users/nbeny/Documents/GitHub/UrbanConnct` | 8 → 10 |

**Branches.** Travailler sur une branche dans chaque dépôt, pas sur `master` / `main`.
Côté `infra` : `feat/livraison-continue`. Côté `UrbanConnct` : `feat/ci-registry-locale`.

⚠️ **Le dépôt `infra` local est partagé entre sessions.** Un `git push` envoie
`HEAD`, donc les commits des autres sessions avec. Ne pousser qu'au moment
voulu, et vérifier `git log origin/master..HEAD` avant.

⚠️ **Argo CD suit `master` de `infra` avec `selfHeal: true`.** Rien de ce qui
touche `kube/urbanlink/` n'a d'effet tant que ce n'est pas sur `master`. La
tâche 11 dit quand fusionner.

**Il n'y a pas de tests unitaires ici** — ni Ansible, ni GitHub Actions, ni
kustomize n'en ont dans ce dépôt. L'équivalent est appliqué à la lettre :
chaque tâche pose d'abord une **vérification qui échoue**, on l'exécute pour
constater l'échec, on implémente, on la relance pour constater le succès. Les
commandes et leur sortie attendue sont écrites en entier.

### Où s'exécute quoi — à lire avant la première commande

⚠️ **Ansible n'est PAS installé sur le poste Windows, et c'est voulu.** Le
README l'énonce : « Sur ton poste Windows — rien d'autre que git et ssh ». Le
seul endroit où Ansible tourne est le nœud PVE, dans `/root/infra/ansible`.
Constaté à la tâche 1 : ni Windows natif, ni WSL kali, ni WSL Ubuntu ne l'ont.

⚠️ **Et `/root/infra` sur le PVE n'est PAS un clone git** — `git status` y
répond « not a git repository ». Un `git pull` est donc impossible : il faut y
déposer les fichiers modifiés avant de jouer quoi que ce soit.

| Outil | Poste Windows | Nœud PVE |
|---|---|---|
| `git` | ✅ (le dépôt vit ici) | ❌ (copie, pas un clone) |
| `ssh` | ✅ | ✅ |
| `ansible` / `ansible-playbook` | ❌ | ✅ (core 2.19.4) |
| `kubectl` | ✅ | ❌ |
| `kustomize` autonome | ❌ | à vérifier |

**Règle de lecture du plan :** toute commande commençant par
`cd .../infra/ansible` se joue **sur le PVE**, après synchronisation. Toute
commande `git`, `kubectl kustomize`, `bash -n` ou d'édition de fichier se joue
**sur le poste**.

**Synchroniser le poste vers le nœud de contrôle**, avant chaque exécution
d'Ansible (`rsync` n'existe pas sur le poste, `tar` sur SSH fait le même
travail) :

```bash
cd C:/Users/nbeny/Documents/GitHub/infra
tar -czf - --exclude=.git ansible kube \
  | ssh root@192.168.100.50 'tar -xzf - -C /root/infra'
```

Puis :

```bash
ssh root@192.168.100.50 'cd /root/infra/ansible && ansible-playbook playbooks/<le playbook>.yml'
```

⚠️ **Cette copie est destructrice pour tout travail non commité présent sur le
nœud.** Elle écrase `/root/infra/ansible` et `/root/infra/kube` par l'état du
poste. Vérifier d'abord qu'on n'y écrase rien :

```bash
ssh root@192.168.100.50 'ls -la /root/infra; find /root/infra -newer /root/infra/README.md -type f -not -path "*/facts_cache/*" | head'
```

⚠️ **Ne pas laisser de fichiers de travail sur le nœud.** Il sert de nœud de
contrôle pour tout le lab ; y abandonner une version intermédiaire d'un
inventaire ferait diverger silencieusement ce qui s'exécute de ce qui est
versionné.

**Pour `kustomize build`** (tâches 4 et 5), `kubectl kustomize .` fait le même
travail et `kubectl` est présent sur le poste. ⚠️ En revanche `kustomize edit
set image` (tâche 10) n'a **pas** d'équivalent `kubectl` : c'est le job de CI
qui le télécharge dans `$RUNNER_TEMP`, comme il le fait déjà aujourd'hui.

**Accès aux VMs.** Elles vivent sur `vmbr1` (`10.0.0.0/24`) et ne sont pas
joignables depuis le LAN. Le rebond part **du poste**, jamais du PVE (dont la
clé RSA correspondante n'existe plus) :

```bash
ssh -J root@192.168.100.50 debian@10.0.0.130     # ci-runner
```

⚠️ **`urbanlink` (10.0.0.111) refuse ce rebond** en `publickey`, même avec
`-i ~/.ssh/id_rsa`. Pour agir dessus, passer par Ansible depuis le PVE, qui a
la bonne clé :

```bash
ssh root@192.168.100.50 'cd /root/infra/ansible && ansible urbanlink -b -m shell -a "kubectl -n urbanconnect get pods"'
```

Les commandes du plan écrites `ssh -J … nbeny@10.0.0.111 '…'` sont donc à
traduire sous cette forme.

---

## Structure des fichiers

### Dépôt `infra`

| Fichier | Action | Responsabilité |
|---|---|---|
| `ansible/inventory/00-static.yml` | Modifier | Déclarer le groupe `ci_nodes` et l'hôte `ci-runner` |
| `ansible/inventory/group_vars/ci_nodes.yml` | Créer | Docker seul — pas de Kubernetes sur cette VM |
| `ansible/roles/registry/defaults/main.yml` | Créer | Port, adresse d'écoute, répertoire de données |
| `ansible/roles/registry/tasks/main.yml` | Créer | Répertoire, unité systemd, démarrage, vérification |
| `ansible/roles/registry/templates/lab-registry.service.j2` | Créer | L'unité systemd qui porte le conteneur |
| `ansible/roles/registry/handlers/main.yml` | Créer | Redémarrage sur changement d'unité |
| `ansible/playbooks/35-ci-registry.yml` | Créer | Point d'entrée du rôle `registry` |
| `ansible/roles/docker/defaults/main.yml` | Modifier | `docker_insecure_registries`, vide par défaut |
| `ansible/roles/docker/tasks/main.yml` | Modifier | `config_path` containerd + `hosts.toml` |
| `kube/urbanlink/config/` | Créer | Copie de `config/` du dépôt applicatif, écrite par la CI |
| `kube/urbanlink/kustomization.yaml` | Modifier | `configMapGenerator` |
| `kube/urbanlink/backend/migrate-job.yaml` | Modifier | Annotations de hook Argo |
| `kube/urbanlink/kratos/migrate-job.yaml` | Modifier | Annotations de hook Argo |
| `kube/urbanlink/kibana/setup-job.yaml` | Modifier | Annotations de hook Argo |
| `ansible/playbooks/31-urbanlink-deploy.yml` | Modifier | Retrait de la section ConfigMaps |
| `ansible/playbooks/32-argocd.yml` | Modifier | `prune: true`, en-tête réécrit |
| `ansible/playbooks/30-urbanlink-images.yml` | Modifier | En-tête : chemin d'amorçage, supplanté par la CI |
| `kube/README.md`, `README.md` | Modifier | Documenter la chaîne |

### Dépôt `UrbanConnct`

| Fichier | Action | Responsabilité |
|---|---|---|
| `.github/workflows/ci.yml` | Modifier | Jobs `images` et `deploy` |
| `scripts/ci/registry-purge.sh` | Créer | Rétention : 10 tags par image, puis garbage-collect |
| `scripts/ci/check-config-declared.sh` | Créer | Garde : tout fichier de config doit être déclaré |
| `config/prod/kratos/kratos.yml` | Modifier | En-tête : le couplage au Secret |

---

## Tâche 1 : Déclarer `ci-runner` dans l'inventaire

**Files:**
- Modify: `ansible/inventory/00-static.yml`
- Create: `ansible/inventory/group_vars/ci_nodes.yml`

- [x] **Étape 1 : Confirmer les valeurs relevées sur la machine**

Relevées le 2026-09-01. ⚠️ `ci-runner` n'a **pas d'agent QEMU** : `qm guest exec`
répond « QEMU guest agent is not running », et un `ssh` depuis le nœud PVE
échoue en `publickey` (sa clé RSA n'existe plus). Le seul chemin qui marche est
le rebond **depuis ce poste** :

```bash
ssh -J root@192.168.100.50 debian@10.0.0.130 \
  'hostname; systemctl list-units "actions.runner.*" --no-pager --plain --no-legend; \
   df -h /var/lib | tail -1; id; command -v jq docker curl rsync'
```

Attendu, et déjà constaté :

| Valeur | Relevé |
|---|---|
| VM | `ci-runner`, VMID 130, démarrée, 12 Go de RAM |
| Adresse | `10.0.0.130` (convention du lab : dernier octet = VMID) |
| Utilisateur du service runner | `debian` (uid 1000) |
| Groupes | **déjà dans `docker` (gid 989)** |
| Disque | 79 Go, 58 Go libres |
| Outils | `jq`, `docker`, `curl`, `rsync` tous présents |

⚠️ **Trois runners sont enregistrés pour `UrbanConnct`** sur cette seule VM
(`ci-runner-urbanlink`, `-2`, `-3`), plus deux pour d'autres dépôts. La matrice
du job `images` peut donc bâtir **les trois images en parallèle sur la même
machine**. Deux conséquences traitées ailleurs dans ce plan : la tâche 9 sort
le ramasse-miettes de la matrice (il est destructeur s'il tourne pendant un
push), et 12 Go de RAM pour trois `npm install` simultanés est serré — c'est le
comportement actuel, on ne le change pas ici, mais c'est le premier suspect si
un build meurt sans message.

⚠️ **`debian` est déjà dans le groupe `docker`.** La déclaration de `docker_users`
à l'étape 4 n'est donc pas un correctif mais un garde-fou : elle inscrit dans le
code un état qui n'existait jusqu'ici que sur la machine, et que rien ne
rétablirait après une reconstruction.

- [x] **Étape 2 : Vérifier que l'hôte n'est pas résolu (l'échec attendu)**

```bash
cd C:/Users/nbeny/Documents/GitHub/infra/ansible
ansible ci-runner --list-hosts
```

Attendu : `[WARNING]: Could not match supplied host pattern, ignoring: ci-runner`
et un code de retour non nul.

- [x] **Étape 3 : Déclarer le groupe et l'hôte**

Dans `ansible/inventory/00-static.yml`, ajouter après le bloc `kali_nodes` :

```yaml
    # VM de CI -- porte le runner GitHub Actions et le registre d'images du lab.
    #
    # ⚠️ Groupe DISTINCT de debian_nodes, et ce n'est pas une coquetterie :
    # ce dernier recoit le role `kubernetes` par site.yml, or cette VM n'a
    # aucun cluster a porter. L'y ranger installerait kubeadm, kubelet et un
    # plan de controle sur une machine dont ce n'est pas le role.
    #
    # ⚠️ Elle n'est PAS gerée par Terraform : elle a ete montee a la main,
    # avant ce depot. On la declare ici pour pouvoir la configurer, sans la
    # reprendre sous Terraform -- ce serait un chantier distinct.
    ci_nodes:
      hosts:
        ci-runner:
          ansible_host: 10.0.0.130   # <- valeur relevee a l'etape 1
```

Puis, dans le groupe parapluie `guests`, ajouter `ci_nodes:` à la liste des
`children` :

```yaml
    guests:
      children:
        debian_nodes:
        kali_nodes:
        ci_nodes:
```

- [x] **Étape 4 : Donner à ce groupe ses variables**

Créer `ansible/inventory/group_vars/ci_nodes.yml` :

```yaml
---
# ============================================================================
#  VM ci-runner -- runner GitHub Actions + registre d'images du lab
# ============================================================================
# Docker, et rien d'autre. Pas de kubernetes : cette VM construit les images,
# elle n'en execute aucune pour le compte du cluster.

docker_users:
  - "{{ ci_runner_service_user }}"
docker_compose_plugin: true

# ⚠️ Le cgroup driver systemd de containerd n'est PAS force ici, contrairement
# a debian_nodes.yml : il n'existe pour satisfaire kubelet, qui n'a rien a
# faire sur cette machine.
docker_containerd_systemd_cgroup: false

# Utilisateur sous lequel tourne le service actions.runner.*. Il doit etre
# dans le groupe docker, sans quoi le job `images` echoue des le premier
# `docker build` sur « permission denied » du socket.
ci_runner_service_user: debian   # <- valeur relevee a la tache 1, etape 1
```

- [x] **Étape 5 : Relancer la vérification**

```bash
cd C:/Users/nbeny/Documents/GitHub/infra/ansible
ansible ci-runner --list-hosts
```

Attendu :
```
  hosts (1):
    ci-runner
```

Puis vérifier que l'hôte répond :

```bash
ansible ci-runner -m ping -e pve_connection=ssh
```

Attendu : `ci-runner | SUCCESS => {"ping": "pong"}`

- [x] **Étape 6 : Vérifier qu'on ne l'a pas rangée dans le mauvais groupe**

```bash
ansible ci-runner --list-hosts --limit debian_nodes
```

Attendu : aucun hôte. Si `ci-runner` apparaît, le groupe est mal placé et
`site.yml` lui installerait Kubernetes.

- [x] **Étape 7 : Commit**

```bash
cd C:/Users/nbeny/Documents/GitHub/infra
git checkout -b feat/livraison-continue
git add ansible/inventory/00-static.yml ansible/inventory/group_vars/ci_nodes.yml
git commit -m "feat(inventaire): la VM de CI n'etait declaree nulle part"
```

---

## Tâche 2 : Rôle `registry` sur `ci-runner`

**Files:**
- Create: `ansible/roles/registry/defaults/main.yml`
- Create: `ansible/roles/registry/templates/lab-registry.service.j2`
- Create: `ansible/roles/registry/handlers/main.yml`
- Create: `ansible/roles/registry/tasks/main.yml`
- Create: `ansible/playbooks/35-ci-registry.yml`

- [x] **Étape 1 : Vérifier que rien n'écoute (l'échec attendu)**

```bash
cd C:/Users/nbeny/Documents/GitHub/infra/ansible
ansible ci-runner -e pve_connection=ssh -m uri \
  -a "url=http://{{ ansible_host }}:5000/v2/ status_code=200"
```

Attendu : `FAILED` — `Connection refused`.

- [x] **Étape 2 : Écrire les valeurs par défaut**

Créer `ansible/roles/registry/defaults/main.yml` :

```yaml
---
# Registre d'images du lab. Il existe parce que la VM qui CONSTRUIT les images
# (ci-runner) et celle qui les EXECUTE (urbanlink) ont chacune leur containerd :
# une image construite d'un cote est invisible de l'autre.
#
# ⚠️ Il n'est PAS sur urbanlink alors que c'est la que les images sont
# consommees. Le couplage que cela cree est reel mais etroit : le tag n'etant
# pas `latest`, imagePullPolicy vaut IfNotPresent, donc une image deja tiree
# reste dans le containerd d'urbanlink. Un redemarrage de pod, un reboot du
# noeud, un rescheduling ne declenchent AUCUN pull. Le registre n'est sollicite
# que pour un tag NEUF -- donc pendant une livraison, donc quand ci-runner
# tourne par construction. Les deux cas d'exposition restants : noeud
# reconstruit, et eviction d'image sous pression disque (seuil haut de kubelet,
# 85 % par defaut).

registry_image: "registry:2"
registry_container_name: lab-registry
registry_port: 5000
registry_data_dir: /var/lib/lab-registry

# ⚠️ Liee a l'adresse de LAN, jamais 0.0.0.0. Le registre est en clair et sans
# authentification : le restreindre a l'interface interne est la seule barriere
# posee ici. Voir « Limites assumees » de la spec.
registry_bind_address: "{{ ansible_host }}"
```

- [x] **Étape 3 : Écrire l'unité systemd**

Créer `ansible/roles/registry/templates/lab-registry.service.j2` :

```ini
# GERE PAR ANSIBLE -- roles/registry. Toute modification manuelle sera ecrasee.
[Unit]
Description=Registre d'images du lab (registry:2)
After=docker.service
Requires=docker.service

[Service]
Restart=always
RestartSec=5
# ⚠️ Le `-` en tete rend l'echec non fatal : au tout premier demarrage aucun
# conteneur ne porte ce nom, et `docker rm` sortirait en erreur, empechant
# ExecStart de s'executer. Sur un redemarrage en revanche, un conteneur
# orphelin peut subsister et tenir le port -- d'ou le nettoyage.
ExecStartPre=-/usr/bin/docker rm -f {{ registry_container_name }}
# `--rm` et non `-d` : c'est systemd qui supervise, pas le demon Docker. Un
# conteneur detache rendrait la main immediatement et systemd considererait le
# service comme termine.
ExecStart=/usr/bin/docker run --rm --name {{ registry_container_name }} \
  -p {{ registry_bind_address }}:{{ registry_port }}:5000 \
  -v {{ registry_data_dir }}:/var/lib/registry \
  -e REGISTRY_STORAGE_DELETE_ENABLED=true \
  {{ registry_image }}
ExecStop=/usr/bin/docker stop {{ registry_container_name }}

[Install]
WantedBy=multi-user.target
```

⚠️ `REGISTRY_STORAGE_DELETE_ENABLED=true` n'est pas une option de confort :
sans elle l'API répond `405 Method Not Allowed` sur toute suppression de
manifeste, et la purge de la tâche 9 devient un no-op **silencieux** — le
disque se remplit sans qu'aucune commande n'échoue.

- [x] **Étape 4 : Écrire le handler**

Créer `ansible/roles/registry/handlers/main.yml` :

```yaml
---
- name: Redemarrer le registre
  ansible.builtin.systemd:
    name: lab-registry
    state: restarted
    daemon_reload: true
```

- [x] **Étape 5 : Écrire les tâches**

Créer `ansible/roles/registry/tasks/main.yml` :

```yaml
---
- name: Creer le repertoire de donnees du registre
  ansible.builtin.file:
    path: "{{ registry_data_dir }}"
    state: directory
    owner: root
    group: root
    mode: "0750"

- name: Deposer l'unite systemd du registre
  ansible.builtin.template:
    src: lab-registry.service.j2
    dest: /etc/systemd/system/lab-registry.service
    owner: root
    group: root
    mode: "0644"
  notify: Redemarrer le registre

- name: Activer et demarrer le registre
  ansible.builtin.systemd:
    name: lab-registry
    enabled: true
    state: started
    daemon_reload: true

# Les handlers ne se declenchent qu'en fin de play : sans ce vidage, la
# verification ci-dessous interrogerait l'ancien conteneur.
- name: Appliquer un eventuel changement d'unite avant de verifier
  ansible.builtin.meta: flush_handlers

- name: Verifier que le registre repond
  ansible.builtin.uri:
    url: "http://{{ registry_bind_address }}:{{ registry_port }}/v2/"
    status_code: 200
  register: registry_probe
  retries: 12
  delay: 5
  until: registry_probe.status is defined and registry_probe.status == 200

# Une suppression refusee ici signifie que REGISTRY_STORAGE_DELETE_ENABLED n'a
# pas pris : le registre fonctionnerait, mais sans jamais pouvoir etre purge.
# Un digest inexistant doit repondre 404 (« je ne l'ai pas ») et non 405
# (« je ne sais pas supprimer »).
- name: Verifier que la suppression de manifeste est autorisee
  ansible.builtin.uri:
    url: >-
      http://{{ registry_bind_address }}:{{ registry_port }}/v2/inexistant/manifests/sha256:{{ '0' * 64 }}
    method: DELETE
    status_code: [404, 400]
  changed_when: false
```

- [x] **Étape 6 : Écrire le playbook**

Créer `ansible/playbooks/35-ci-registry.yml` :

```yaml
---
# Installe le registre d'images du lab sur la VM de CI.
#
#   ansible-playbook playbooks/35-ci-registry.yml
#
# Pourquoi un registre, alors que 30-urbanlink-images.yml s'en passe : ce
# playbook-la construit les images SUR urbanlink, et un `ctr import` local
# suffit. Le runner GitHub, lui, tourne sur ci-runner -- les deux containerd
# sont distincts, et une image construite sur l'un est invisible de l'autre.
#
# ⚠️ Ce playbook ne suffit pas a rendre les images tirables : il faut aussi
# autoriser containerd, cote urbanlink, a parler a un registre en clair.
# C'est le role `docker` qui le fait, via `docker_insecure_registries` --
# voir playbooks/20-debian-k8s.yml.

- name: Installer le registre d'images du lab
  hosts: ci_nodes
  gather_facts: true
  become: true

  roles:
    - registry

  post_tasks:
    - name: Recapitulatif
      ansible.builtin.debug:
        msg:
          - "Registre : http://{{ ansible_host }}:{{ registry_port }}/v2/"
          - ""
          - "Cote urbanlink, pour que containerd accepte ce registre en clair :"
          - "  ansible-playbook playbooks/20-debian-k8s.yml -l urbanlink"
          - "  (avec docker_insecure_registries renseigne dans host_vars/urbanlink.yml)"
          - ""
          - "Catalogue :  curl http://{{ ansible_host }}:{{ registry_port }}/v2/_catalog"
```

- [x] **Étape 7 : Jouer le playbook**

```bash
cd C:/Users/nbeny/Documents/GitHub/infra/ansible
ansible-playbook playbooks/35-ci-registry.yml -e pve_connection=ssh
```

Attendu : `ok=7 changed=3 failed=0`.

- [x] **Étape 8 : Relancer la vérification de l'étape 1**

```bash
ansible ci-runner -e pve_connection=ssh -m uri \
  -a "url=http://{{ ansible_host }}:5000/v2/ status_code=200"
```

Attendu : `SUCCESS`, `status: 200`.

- [x] **Étape 9 : Vérifier l'idempotence**

```bash
ansible-playbook playbooks/35-ci-registry.yml -e pve_connection=ssh
```

Attendu : `changed=0`. Un `changed` au second passage signifie qu'une tâche
n'est pas idempotente et redémarrerait le registre à chaque exécution.

- [x] **Étape 10 : Commit**

```bash
cd C:/Users/nbeny/Documents/GitHub/infra
git add ansible/roles/registry ansible/playbooks/35-ci-registry.yml
git commit -m "feat(registry): les images construites sur ci-runner etaient invisibles d'urbanlink"
```

---

## Tâche 3 : Autoriser containerd à tirer depuis un registre en clair

**Files:**
- Modify: `ansible/roles/docker/defaults/main.yml`
- Modify: `ansible/roles/docker/tasks/main.yml`
- Modify: `ansible/inventory/host_vars/urbanlink.yml`

- [x] **Étape 1 : Constater l'échec du pull (la vérification qui échoue)**

D'abord pousser une image de test depuis `ci-runner` :

```bash
ssh -J root@192.168.100.50 debian@10.0.0.130 \
  'docker pull alpine:3.20 \
   && docker tag alpine:3.20 10.0.0.130:5000/alpine:test \
   && docker push 10.0.0.130:5000/alpine:test'
```

Attendu : le push réussit (Docker traite les adresses IP privées comme des
registres non sécurisés par défaut).

Puis, depuis `urbanlink` :

```bash
ssh -J root@192.168.100.50 nbeny@10.0.0.111 \
  'sudo crictl pull 10.0.0.130:5000/alpine:test'
```

Attendu : échec sur `failed to do request: Head "https://10.0.0.130:5000/v2/...":
http: server gave HTTP response to HTTPS client`.

⚠️ Noter le message : containerd parle **https** à un registre en clair. C'est
le symptôme exact que corrige cette tâche.

- [x] **Étape 2 : Ajouter la variable par défaut**

Dans `ansible/roles/docker/defaults/main.yml`, ajouter :

```yaml
# Registres joignables en HTTP, sans certificat. Vide par defaut : un registre
# en clair est un choix, jamais un defaut.
#
# Chaque entree produit un /etc/containerd/certs.d/<hote>/hosts.toml. Format :
#   docker_insecure_registries:
#     - "10.0.0.42:5000"
docker_insecure_registries: []
```

- [x] **Étape 3 : Poser `config_path` et les `hosts.toml`**

Dans `ansible/roles/docker/tasks/main.yml`, à la fin du bloc « Configurer
containerd », ajouter :

```yaml
    # ⚠️ SANS CETTE LIGNE, TOUT LE RESTE EST IGNORE EN SILENCE.
    # containerd ne lit /etc/containerd/certs.d que si `config_path` l'y
    # envoie ; or `containerd config default` (tache plus haut) laisse ce champ
    # VIDE. Les hosts.toml sont alors ecrits, presents, lisibles -- et jamais
    # consultes. Le pull echoue sur une erreur TLS qui n'evoque rien du
    # probleme : « server gave HTTP response to HTTPS client ».
    #
    # ⚠️ **La section a change de nom en containerd 2.x.** Le noeud tourne
    # v2.3.4 (releve le 2026-09-01), ou elle s'ecrit
    # `[plugins.'io.containerd.cri.v1.images'.registry]` -- en guillemets
    # SIMPLES. L'ancienne `[plugins."io.containerd.grpc.v1.cri".registry]`
    # n'existe plus : un `insertafter` qui la cherche ne matche jamais, et
    # `lineinfile` ajoute alors la ligne EN FIN DE FICHIER, hors de toute
    # section.
    #
    # ⚠️ Et surtout, PAS de `lineinfile` avec un `regexp` nu ici : le fichier
    # contient TROIS lignes `config_path` (registre, plugin NRI, plugin de
    # transfert). `lineinfile` remplace la DERNIERE correspondance -- il
    # toucherait celle du transfert d'images, pas celle du registre. D'ou le
    # `replace` ancre sur l'en-tete de section, qui ne peut viser qu'elle.
    - name: Faire lire /etc/containerd/certs.d par containerd
      ansible.builtin.replace:
        path: /etc/containerd/config.toml
        regexp: >-
          (\[plugins\.'io\.containerd\.cri\.v1\.images'\.registry\]\s*\n\s*config_path\s*=\s*)'[^']*'
        replace: "\\1'/etc/containerd/certs.d'"
      notify: Redemarrer containerd

    # Un `replace` qui ne matche rien ne signale RIEN -- il rapporte
    # simplement `changed: false`, indistinguable d'un fichier deja correct.
    # Cette verification transforme ce silence en echec.
    - name: Verifier que config_path a bien ete pose
      ansible.builtin.command:
        cmd: >-
          grep -Pzo (?s)\[plugins\.'io\.containerd\.cri\.v1\.images'\.registry\].*?config_path\s*=\s*'/etc/containerd/certs\.d'
          /etc/containerd/config.toml
      changed_when: false

- name: Declarer les registres en clair
  when: docker_insecure_registries | length > 0
  block:

    - name: Creer les repertoires de configuration des registres
      ansible.builtin.file:
        path: "/etc/containerd/certs.d/{{ item }}"
        state: directory
        owner: root
        group: root
        mode: "0755"
      loop: "{{ docker_insecure_registries }}"

    # `skip_verify` seul ne suffit PAS : il desactive la verification du
    # certificat, pas le passage en HTTPS. C'est le prefixe `http://` du champ
    # `server` qui fait parler containerd en clair.
    - name: Deposer les hosts.toml
      ansible.builtin.copy:
        dest: "/etc/containerd/certs.d/{{ item }}/hosts.toml"
        owner: root
        group: root
        mode: "0644"
        content: |
          # GERE PAR ANSIBLE -- roles/docker, docker_insecure_registries.
          server = "http://{{ item }}"

          [host."http://{{ item }}"]
            capabilities = ["pull", "resolve"]
            skip_verify = true
      loop: "{{ docker_insecure_registries }}"
      notify: Redemarrer containerd
```

- [x] **Étape 4 : Vérifier que le handler existe**

```bash
cat C:/Users/nbeny/Documents/GitHub/infra/ansible/roles/docker/handlers/main.yml
```

Si aucun handler `Redemarrer containerd` n'y figure, l'ajouter :

```yaml
- name: Redemarrer containerd
  ansible.builtin.systemd:
    name: containerd
    state: restarted
    daemon_reload: true
```

⚠️ containerd relit `config.toml` au **démarrage**, pas en continu. Sans ce
redémarrage, la configuration est correcte sur le disque et sans effet.

- [x] **Étape 5 : Déclarer le registre côté `urbanlink`**

Dans `ansible/inventory/host_vars/urbanlink.yml`, ajouter :

```yaml
# --- Registre d'images du lab ---------------------------------------------
# Les images applicatives sont construites sur ci-runner et poussees dans le
# registre qui y tourne (roles/registry). containerd doit donc accepter de le
# joindre en clair : voir docker_insecure_registries dans roles/docker.
#
# ⚠️ Le PULL ne quitte pas le LAN, mais il quitte bien la VM : ce registre
# n'est pas ici. Si ci-runner est eteinte, un tag NEUF est intirable -- un tag
# deja present, lui, ne declenche aucun pull (imagePullPolicy IfNotPresent).
docker_insecure_registries:
  - "10.0.0.130:5000"   # <- ci-runner, valeur relevee a la tache 1
```

- [x] **Étape 6 : Appliquer sur `urbanlink`**

```bash
cd C:/Users/nbeny/Documents/GitHub/infra/ansible
ansible-playbook playbooks/20-debian-k8s.yml -l urbanlink -e pve_connection=ssh --tags docker
```

Si le playbook n'a pas de tag `docker`, le jouer en entier — il est idempotent.

- [x] **Étape 7 : Relancer la vérification de l'étape 1**

```bash
ssh -J root@192.168.100.50 nbeny@10.0.0.111 \
  'sudo crictl pull 10.0.0.130:5000/alpine:test && sudo crictl images | grep alpine'
```

Attendu : `Image is up to date for ...` puis une ligne listant l'image.

**C'est la vérification qui compte dans toute cette tâche** : elle valide d'un
coup la route réseau, le `hosts.toml`, le `config_path` et le redémarrage.

- [x] **Étape 8 : Nettoyer l'image de test**

```bash
ssh -J root@192.168.100.50 nbeny@10.0.0.111 \
  'sudo crictl rmi 10.0.0.130:5000/alpine:test'
```

- [x] **Étape 9 : Commit**

```bash
cd C:/Users/nbeny/Documents/GitHub/infra
git add ansible/roles/docker ansible/inventory/host_vars/urbanlink.yml
git commit -m "feat(containerd): un registre en clair etait injoignable, et le hosts.toml ignore"
```

---

## Tâche 4 : `configMapGenerator` dans le kustomization

**Files:**
- Create: `kube/urbanlink/config/` (copie initiale, à la main)
- Modify: `kube/urbanlink/kustomization.yaml`

- [x] **Étape 1 : Constater que kustomize ne génère rien (l'échec attendu)**

```bash
cd C:/Users/nbeny/Documents/GitHub/infra/kube/urbanlink
kubectl kustomize . | grep -c "kind: ConfigMap"
```

Attendu : **`1`**, et non `0`. ⚠️ Cette ConfigMap-là est
`oathkeeper/configmap.yaml`, déjà listée en ressource : elle porte les règles
d'accès d'Oathkeeper, elle ne vient pas de `config/` et n'a rien à voir avec
cette tâche. Aucune des cinq ConfigMaps de configuration applicative ne sort du
build aujourd'hui — elles sont toutes créées hors kustomize, par
`31-urbanlink-deploy.yml`.

⇒ **Le compte attendu après cette tâche est donc `6`, pas `5`.**

- [x] **Étape 2 : Déposer une première copie de `config/`**

Cette copie sera ensuite écrasée par la CI à chaque livraison ; elle est faite
à la main ici pour que le kustomization soit buildable tout de suite.

```bash
cd C:/Users/nbeny/Documents/GitHub/infra
mkdir -p kube/urbanlink/config
cp -r C:/Users/nbeny/Documents/GitHub/UrbanConnct/config/common kube/urbanlink/config/
cp -r C:/Users/nbeny/Documents/GitHub/UrbanConnct/config/prod   kube/urbanlink/config/
# ⚠️ La documentation ne part PAS dans le cluster et n'a rien a faire ici.
# `config/common/kratos/CLAUDE.md` et `config/common/kibana/README.md` ne sont
# montes par rien (ils ne figurent dans aucun configMapGenerator) : les copier
# n'ajouterait que du bruit -- et CLAUDE.md documente le format JSON du bloc
# `providers` de Kratos avec un exemple contenant les chaines `GOCSPX-` et
# `apps.googleusercontent.com`, ce qui declenche la garde ci-dessous pour rien.
find kube/urbanlink/config -name CLAUDE.md -o -name README.md | xargs -r rm
```

Vérifier qu'aucun secret réel n'y entre :

```bash
grep -rn "GOCSPX-\|apps.googleusercontent.com" kube/urbanlink/config/ | grep -v "CHANGE_ME\|REPLACE"
```

Attendu : aucune sortie.

⚠️ Si cette commande renvoie quelque chose, **arrêter** : un identifiant réel
s'apprête à être commité dans un dépôt git.

⚠️ **Ne pas relâcher la garde sur un faux positif sans avoir lu la ligne.**
Constaté le 2026-09-01 sur `config/common/kratos/CLAUDE.md` : le `client_id` y
vaut `…apps.googleusercontent.com` — une ellipse, aucun identifiant — et le
`client_secret` vaut `GOCSPX-le-vrai-secret`, c'est-à-dire l'étiquette
« le-vrai-secret », pas une valeur. C'était bien de la documentation. La
suppression ci-dessus retire la cause plutôt que d'assouplir la garde ; élargir
le filtre `CHANGE_ME|REPLACE` aurait au contraire ouvert la porte au jour où un
vrai secret passerait.

- [x] **Étape 3 : Écrire le `configMapGenerator`**

À la fin de `kube/urbanlink/kustomization.yaml`, après le bloc `resources:` :

```yaml
# ============================================================================
#  ConfigMaps de configuration applicative
# ============================================================================
# Les fichiers de config/ viennent du depot APPLICATIF (UrbanConnct), a cote
# du docker-compose.yml qui monte les memes en dev. C'est ce qui empeche un
# reglage de diverger entre les deux environnements -- il n'existe qu'une fois.
# La CI de ce depot-la les recopie ici a chaque livraison sur main.
#
# ⚠️ **Le suffixe de hash est le mecanisme, pas un effet de bord.** Le nom
# genere depend du CONTENU (kratos-config-7f3d9k) : changer un fichier change
# le nom, kustomize reecrit toutes les references dans le meme build, la spec
# des Deployments change, et les pods redemarrent. C'est la seule facon
# d'obtenir un redemarrage automatique -- modifier une ConfigMap en place n'en
# provoque aucun.
#
# ⚠️ Consequence a connaitre AVANT de toucher a ces fichiers : un changement
# dans postgres-init redemarre Postgres, un changement dans nominatim.env
# redemarre Nominatim (33 Go d'OSM importes, le PVC est conserve mais le
# redemarrage est long).
#
# ⚠️ **`envs:` et non `files:` pour les deux fichiers d'environnement.**
# pgbouncer et nominatim les consomment par `envFrom: configMapRef:`, qui
# attend une ConfigMap dont CHAQUE CLE est une variable. `files:` produirait
# une cle unique nommee comme le fichier, contenant tout son texte : le pod
# echoue alors sur une variable absente alors qu'elle figure bien dedans.
# Mesure sur la VM : pgbouncer refusait de demarrer sur « DB_HOST: Setup
# pgbouncer config error! » avec DB_HOST=postgres present dans le fichier.
#
# ⚠️ **Liste explicite, kustomize n'acceptant pas de repertoire.** Deux ecarts
# assumes par rapport a ce que produisait 31-urbanlink-deploy.yml, tous deux
# sans effet fonctionnel :
#   - CLAUDE.md n'entre plus dans kratos-config. Il y etait par accident,
#     `--from-file=<repertoire>` prenant tout ce qu'il trouve.
#   - Les sous-repertoires common/kratos/{email,email-templates,scripts}
#     restent exclus. Ils l'etaient deja : --from-file ne recurse pas.
# La garde scripts/ci/check-config-declared.sh du depot applicatif echoue si
# un fichier apparait dans config/ sans etre liste ici -- sans elle, l'ajout
# d'un fichier le laisserait silencieusement hors du cluster.
configMapGenerator:
  - name: kratos-config
    files:
      - config/common/kratos/identity.schema.json
      - config/common/kratos/oidc.google.jsonnet
      - config/prod/kratos/kratos.yml
  - name: postgres-init
    files:
      - config/common/postgres-init/create-databases.sh
      - config/common/postgres-init/init-db.sql
  - name: pgbouncer-config
    envs:
      - config/prod/pgbouncer/pgbouncer.env
  - name: nominatim-config
    envs:
      - config/prod/nominatim/nominatim.env
  - name: kibana-dashboards
    files:
      - config/common/kibana/dashboards.ndjson
```

- [x] **Étape 4 : Vérifier que les cinq ConfigMaps sortent du build**

```bash
cd C:/Users/nbeny/Documents/GitHub/infra/kube/urbanlink
kustomize build . | grep -c "kind: ConfigMap"
```

Attendu : `6` — les cinq du generator, plus `oathkeeper/configmap.yaml`.

- [x] **Étape 5 : Vérifier que les références sont réécrites**

C'est le point qui fait tout marcher. Si les Deployments pointent encore sur
`kratos-config` sans suffixe, les pods ne redémarreront jamais.

```bash
kustomize build . | grep -o "kratos-config[a-z0-9-]*" | sort -u
```

Attendu : **une seule valeur**, de la forme `kratos-config-<hash>`. Si
`kratos-config` nu apparaît aussi, une référence n'a pas été réécrite.

- [x] **Étape 6 : Vérifier la forme des deux ConfigMaps d'environnement**

```bash
kustomize build . | grep -A6 "name: pgbouncer-config"
```

Attendu : plusieurs clés (`DB_HOST`, `POOL_MODE`, …), **pas** une clé unique
nommée `pgbouncer.env`.

- [x] **Étape 7 : Vérifier que le hash bouge avec le contenu**

⚠️ **La sonde doit être une vraie paire `CLÉ=valeur`, pas un commentaire.**
Mesure du 2026-09-01 : `echo "# test" >> pgbouncer.env` laisse le hash
**inchangé**, et on conclurait à tort que le mécanisme est cassé. `envs:`
applique la sémantique env-file — lignes vides et commentaires sont ignorés à
la construction des clés — donc la ConfigMap produite est identique au
caractère près. Ce n'est pas un défaut, c'est le comportement correct.

```bash
kubectl kustomize . | grep -o "pgbouncer-config-[a-z0-9]*" | head -1
printf 'PROBE_VAR=1\n' >> config/prod/pgbouncer/pgbouncer.env
kubectl kustomize . | grep -o "pgbouncer-config-[a-z0-9]*" | head -1
```

Attendu : les deux valeurs diffèrent. C'est la preuve directe que le
redémarrage automatique fonctionnera.

Puis restaurer, et **le vérifier** — à ce stade le fichier peut ne pas encore
être suivi par git, auquel cas `git checkout` ne restaure rien :

```bash
git checkout kube/urbanlink/config/prod/pgbouncer/pgbouncer.env 2>/dev/null \
  || sed -i '/^PROBE_VAR=1$/d' kube/urbanlink/config/prod/pgbouncer/pgbouncer.env
diff kube/urbanlink/config/prod/pgbouncer/pgbouncer.env \
     C:/Users/nbeny/Documents/GitHub/UrbanConnct/config/prod/pgbouncer/pgbouncer.env
```

Attendu : aucune différence.

- [x] **Étape 8 : Commit**

```bash
cd C:/Users/nbeny/Documents/GitHub/infra
git add kube/urbanlink/config kube/urbanlink/kustomization.yaml
git commit -m "feat(config): un changement dans config/ n'atteignait jamais le cluster"
```

---

## Tâche 5 : Convertir les trois Jobs en hooks Argo

**Files:**
- Modify: `kube/urbanlink/backend/migrate-job.yaml`
- Modify: `kube/urbanlink/kratos/migrate-job.yaml`
- Modify: `kube/urbanlink/kibana/setup-job.yaml`

- [x] **Étape 1 : Constater l'absence d'annotation (l'échec attendu)**

```bash
cd C:/Users/nbeny/Documents/GitHub/infra/kube/urbanlink
kustomize build . | grep -c "argocd.argoproj.io/hook"
```

Attendu : `0`.

Pourquoi c'est un défaut : `kustomize edit set image` (tâche 10) réécrit
`backend/migrate-job.yaml:62`, donc la spec du Job change **à chaque
livraison**. Un `kubectl apply` sur un Job existant échoue en « field is
immutable » — c'est pour ça que `31-urbanlink-deploy.yml:478` les supprime
d'abord. `Replace=false` et `ApplyOutOfSyncOnly=true` ne sauvent pas : le Job
sera hors-sync, donc appliqué, donc en échec.

- [x] **Étape 2 : Annoter `backend/migrate-job.yaml`**

Dans les `metadata:` du Job (autour de la ligne 31) :

```yaml
metadata:
  name: backend-migrate
  # ⚠️ Hook Argo, et non ressource ordinaire. La section `images:` du
  # kustomization epingle le tag du backend, qui figure AUSSI ici : la spec de
  # ce Job change donc a chaque livraison. Or les champs d'un Job sont
  # immuables -- `kubectl apply` echoue en « field is immutable » des que le
  # Job existe. `BeforeHookCreation` le supprime puis le recree, ce que
  # 31-urbanlink-deploy.yml faisait a la main avant Argo.
  #
  # `PreSync` et non `Sync` : la migration doit s'achever AVANT que les
  # nouveaux pods du backend ne demarrent. Cet ordre n'etait garanti par rien
  # jusqu'ici.
  annotations:
    argocd.argoproj.io/hook: PreSync
    argocd.argoproj.io/hook-delete-policy: BeforeHookCreation
```

- [x] **Étape 3 : Annoter `kratos/migrate-job.yaml`**

Mêmes annotations, avec ce commentaire :

```yaml
  # ⚠️ Hook Argo PreSync. La ConfigMap kratos-config etant generee avec un
  # suffixe de hash, la reference montee par ce Job change des que la config
  # de Kratos change -- donc sa spec change, donc `apply` echouerait sur
  # l'immuabilite. Et la migration doit precéder le demarrage de Kratos.
  annotations:
    argocd.argoproj.io/hook: PreSync
    argocd.argoproj.io/hook-delete-policy: BeforeHookCreation
```

- [x] **Étape 4 : Annoter `kibana/setup-job.yaml`**

```yaml
  # ⚠️ Hook Argo PreSync : ce Job monte la ConfigMap kibana-dashboards, dont
  # le nom porte desormais un hash. Modifier un tableau de bord change ce nom,
  # donc la spec du Job.
  #
  # `PreSync` alors qu'il attend que Kibana soit `available` : le Job porte
  # deja cette attente lui-meme (voir son en-tete), la phase ne la remplace
  # pas. C'est l'immuabilite qu'on traite ici, pas l'ordonnancement.
  annotations:
    argocd.argoproj.io/hook: PreSync
    argocd.argoproj.io/hook-delete-policy: BeforeHookCreation
```

- [x] **Étape 5 : Ne PAS annoter `minio-init` ni `elasticsearch-setup`**

Vérifier qu'ils sont restés intacts :

```bash
cd C:/Users/nbeny/Documents/GitHub/infra/kube/urbanlink
grep -c "argocd.argoproj.io/hook" minio/init-job.yaml elasticsearch/setup-job.yaml
```

Attendu : `0` pour les deux. Ni leur image (`minio/mc`, `curlimages/curl` ou
équivalent) ni leur configuration ne bougent : ils ne repassent jamais
hors-sync, donc le problème d'immuabilité ne les touche pas. Les convertir les
ferait rejouer à chaque synchronisation sans raison.

- [x] **Étape 6 : Relancer la vérification**

```bash
kustomize build . | grep -c "argocd.argoproj.io/hook:"
```

Attendu : `3`.

```bash
kustomize build . | grep -B3 "argocd.argoproj.io/hook:" | grep "name:"
```

Attendu : `backend-migrate`, `kratos-migrate`, et le nom du Job de setup Kibana.

- [x] **Étape 7 : Commit**

```bash
cd C:/Users/nbeny/Documents/GitHub/infra
git add kube/urbanlink/backend/migrate-job.yaml \
        kube/urbanlink/kratos/migrate-job.yaml \
        kube/urbanlink/kibana/setup-job.yaml
git commit -m "fix(argo): trois Jobs immuables auraient fait echouer chaque synchronisation"
```

---

## Tâche 6 : Retirer les ConfigMaps d'Ansible 31

**Files:**
- Modify: `ansible/playbooks/31-urbanlink-deploy.yml:188-266`

- [x] **Étape 1 : Constater le doublon (l'échec attendu)**

```bash
grep -c "Creer les ConfigMaps prerequises" \
  C:/Users/nbeny/Documents/GitHub/infra/ansible/playbooks/31-urbanlink-deploy.yml
```

Attendu : `1`. Laisser cette tâche recréerait les cinq ConfigMaps **sans**
suffixe de hash, à côté de celles d'Argo : des objets que plus personne ne
monte, et qui laisseraient croire que la configuration vient de là.

- [x] **Étape 2 : Supprimer la tâche**

Retirer entièrement le bloc `- name: Creer les ConfigMaps prerequises` (l.188 à
l.266, jusqu'à `changed_when: true` inclus).

- [x] **Étape 3 : Réécrire l'en-tête du playbook**

Remplacer la description des prérequis en tête de fichier par :

```yaml
# Amorce le stack UrbanLink : ce qu'Argo CD ne peut PAS reconcilier.
#
# ⚠️ Ce playbook ne cree PLUS les cinq ConfigMaps de configuration. Elles sont
# desormais generees par le `configMapGenerator` de kube/urbanlink/, depuis la
# copie de config/ que la CI du depot applicatif ecrit dans ce depot. Les
# recreer ici produirait des doublons non hashes que plus rien ne monte.
#
# Ce qui reste ici, et pourquoi Argo ne peut pas le reprendre :
#   1. Le Secret urbanconnect-secrets, construit depuis un secrets.env
#      DELIBEREMENT non versionne. Un GitOps qui lirait les secrets dans git
#      supposerait qu'ils y soient -- exactement ce qu'on refuse.
#   2. L'AuthorizationPolicy de la passerelle, qui doit vivre dans
#      istio-ingress alors que le kustomization force `namespace: urbanconnect`.
#   3. Le certificat auto-signe de la passerelle.
#   4. Le namespace et ses labels de maillage.
```

- [x] **Étape 4 : Documenter le couplage résiduel**

Juste avant la tâche `- name: Lire la configuration Kratos de l'environnement`
(vers la l.361 avant suppression), ajouter :

```yaml
    # ⚠️ **LE SEUL ENDROIT OU config/ NE SE PROPAGE PAS TOUT SEUL.**
    # KRATOS_OIDC_PROVIDERS est DERIVE de config/prod/kratos/kratos.yml : on y
    # lit la structure `providers`, on y injecte les vrais identifiants Google,
    # et le resultat part dans le Secret -- pas dans la ConfigMap.
    #
    # Consequence : changer les fournisseurs OIDC dans ce fichier propage la
    # ConfigMap automatiquement (la CI la recopie, le hash change, Kratos
    # redemarre) mais PAS le Secret. Il faut rejouer ce playbook.
    #
    # Et la panne est MUETTE : Kratos demarre normalement, tout fonctionne,
    # seule la connexion Google repond « Impossible d'initier la connexion ».
```

- [x] **Étape 5 : Vérifier la syntaxe**

```bash
cd C:/Users/nbeny/Documents/GitHub/infra/ansible
ansible-playbook playbooks/31-urbanlink-deploy.yml --syntax-check
```

Attendu : `playbook: playbooks/31-urbanlink-deploy.yml`, sans erreur.

- [x] **Étape 6 : Relancer la vérification de l'étape 1**

```bash
grep -c "Creer les ConfigMaps prerequises" \
  C:/Users/nbeny/Documents/GitHub/infra/ansible/playbooks/31-urbanlink-deploy.yml
```

Attendu : `0`.

Vérifier que le Secret est resté :

```bash
grep -c "Creer le Secret applicatif" \
  C:/Users/nbeny/Documents/GitHub/infra/ansible/playbooks/31-urbanlink-deploy.yml
```

Attendu : `1`.

- [x] **Étape 7 : Commit**

```bash
cd C:/Users/nbeny/Documents/GitHub/infra
git add ansible/playbooks/31-urbanlink-deploy.yml
git commit -m "refactor(ansible): les ConfigMaps auraient fait doublon avec celles d'Argo"
```

---

## Tâche 7 : Activer `prune` et réécrire l'en-tête d'Argo

**Files:**
- Modify: `ansible/playbooks/32-argocd.yml`

- [x] **Étape 1 : Constater l'état actuel (l'échec attendu)**

```bash
grep -n "prune: false" C:/Users/nbeny/Documents/GitHub/infra/ansible/playbooks/32-argocd.yml
```

Attendu : une ligne trouvée. Avec `prune: false`, chaque livraison ajoute cinq
ConfigMaps hashées que rien ne supprime jamais.

- [x] **Étape 2 : Basculer `prune`**

Remplacer le commentaire (l.317-326) et la valeur :

```yaml
    # ⚠️ `prune: true` depuis que les ConfigMaps sont generees avec un suffixe
    # de hash : chaque changement de configuration cree un objet NOUVEAU, et
    # sans elagage l'ancien resterait indefiniment. Cinq de plus par livraison.
    #
    # Ce que cela coute : une suppression dans git devient une suppression dans
    # le cluster sans qu'un humain la voie passer -- y compris si le chemin
    # surveille se vide par accident (renommage, branche mal ciblee).
    #
    # Ce que cela ne touche PAS : ce qu'Argo n'a pas cree. Le Secret
    # urbanconnect-secrets et l'AuthorizationPolicy, poses par
    # 31-urbanlink-deploy.yml, sont hors de son champ.
    #
    # Pour revenir en arriere :
    #   kubectl -n argocd patch application urbanlink --type merge \
    #     -p '{"spec":{"syncPolicy":{"automated":{"prune":false}}}}'
    - name: Declarer l'Application UrbanLink
```

et dans le manifeste :

```yaml
            syncPolicy:
              automated:
                prune: true
                selfHeal: true
```

- [x] **Étape 3 : Réécrire l'en-tête du playbook**

Le bloc « Ce qu'Argo CD ne peut PAS reprendre » (l.14-41) perd son point 1 et
son avertissement final. Le remplacer par :

```yaml
# ============================================================================
#  Ce qu'Argo CD ne peut PAS reprendre, et pourquoi
# ============================================================================
#
# Argo CD applique la sortie de `kustomize build`. Deux choses lui sont donc
# structurellement inaccessibles :
#
#   1. **Le Secret `urbanconnect-secrets`**, construit depuis un `secrets.env`
#      deliberement NON versionne. Un GitOps qui lirait les secrets depuis git
#      supposerait qu'ils y soient -- exactement ce qu'on refuse.
#   2. **L'AuthorizationPolicy de la passerelle**, qui doit vivre dans
#      `istio-ingress` alors que le kustomization force `namespace:
#      urbanconnect`.
#
# ⚠️ Les ConfigMaps de configuration NE SONT PLUS dans cette liste. Elles
# etaient inaccessibles a Argo tant que leur source vivait uniquement dans le
# depot applicatif ; la CI de celui-ci les recopie desormais dans
# kube/urbanlink/config/, et un `configMapGenerator` les monte. Un changement
# dans `config/` se propage donc TOUT SEUL, redemarrage des pods compris --
# ce qui n'etait pas le cas avant le 2026-09-01.
#
# ⇒ **Le partage des roles** : ansible amorce (Secret, politique de
#   passerelle, certificat, namespace), Argo CD reconcilie tout le reste.
```

- [x] **Étape 4 : Vérifier la syntaxe et relancer la vérification**

```bash
cd C:/Users/nbeny/Documents/GitHub/infra/ansible
ansible-playbook playbooks/32-argocd.yml --syntax-check
grep -c "prune: true" playbooks/32-argocd.yml
grep -c "prune: false" playbooks/32-argocd.yml
```

Attendu : syntaxe OK, puis `1` et `0`.

⚠️ **Ne pas jouer ce playbook maintenant.** `prune` sur une Application dont la
synchronisation échoue peut supprimer ce qu'elle n'arrive pas à recréer. La
tâche 11 dit à quel moment le jouer.

- [x] **Étape 5 : Commit**

```bash
cd C:/Users/nbeny/Documents/GitHub/infra
git add ansible/playbooks/32-argocd.yml
git commit -m "feat(argo): sans elagage, cinq ConfigMaps de plus s'accumulaient par livraison"
```

---

## Tâche 8 : Réécrire le job `images` sans GHCR

**Files:**
- Modify: `UrbanConnct/.github/workflows/ci.yml:327-425`

- [x] **Étape 1 : Constater la dépendance à GHCR (l'échec attendu)**

```bash
cd C:/Users/nbeny/Documents/GitHub/UrbanConnct
grep -c "ghcr.io" .github/workflows/ci.yml
```

Attendu : une valeur supérieure à `0`.

Pourquoi c'est un défaut : le plan GitHub Free plafonne les paquets privés à
500 Mo de stockage et 1 Go/mois de transfert. Les trois images sont des images
Node ; le quota saute au premier build, et le `cache-to: mode=max` actuel
pousse en plus toutes les couches intermédiaires.

- [x] **Étape 2 : Créer la branche**

```bash
cd C:/Users/nbeny/Documents/GitHub/UrbanConnct
git checkout -b feat/ci-registry-locale
```

- [x] **Étape 3 : Remplacer le corps du job `images`**

Conserver `name`, `needs`, `if`, `runs-on`, `strategy` et la matrice à
l'identique. Remplacer `permissions`, `outputs` et `steps` par :

```yaml
    # `packages: write` n'a plus lieu d'etre : plus rien ne part chez GitHub.
    permissions:
      contents: read
    outputs:
      tag: ${{ steps.meta.outputs.tag }}
    steps:
      - uses: actions/checkout@v4

      - name: Identité de l'image
        id: meta
        run: |
          set -euo pipefail
          # Le tag EST le commit : immuable, tracable, et c'est lui qu'Argo CD
          # epinglera. Un tag mouvant (`latest`, `main`) rendrait le depot
          # d'infrastructure incapable de dire ce qui tourne reellement.
          echo "tag=sha-$(git rev-parse --short HEAD)" >> "$GITHUB_OUTPUT"

      # ⚠️ Ni `setup-buildx`, ni `docker/login-action`, ni
      # `docker/build-push-action` : le runner est PERSISTANT (self-hosted sur
      # la VM ci-runner), donc le cache de couches du demon Docker survit d'un
      # build a l'autre. C'est plus rapide qu'un cache de registre, et gratuit.
      # Un runner jetable justifiait le cache distant ; celui-ci ne l'est pas.
      - name: Construire l'image
        run: |
          set -euo pipefail
          docker build \
            -f '${{ matrix.dockerfile }}' \
            ${{ matrix.target && format('--target {0}', matrix.target) || '' }} \
            -t '${{ vars.LAB_REGISTRY }}/${{ matrix.name }}:${{ steps.meta.outputs.tag }}' \
            ${{ matrix.context == 'front' && format(
              '--build-arg NEXT_PUBLIC_API_URL=https://api.urbanlink.fr
               --build-arg NEXT_PUBLIC_GRAPHQL_URL=https://api.urbanlink.fr/graphql
               --build-arg NEXT_PUBLIC_GRAPHQL_WS_URL=wss://api.urbanlink.fr/graphql
               --build-arg NEXT_PUBLIC_KRATOS_PUBLIC_URL=https://auth.urbanlink.fr
               --build-arg NEXT_PUBLIC_SITE_URL=https://urbanlink.fr
               --build-arg NEXT_PUBLIC_STRIPE_PUBLIC_KEY={0}
               --build-arg MINIO_PROXY_URL=http://minio:9000
               --build-arg KRATOS_PROXY_URL=http://kratos:4433
               --build-arg BACKEND_PROXY_URL=http://backend:4000
               --build-arg NOMINATIM_PROXY_URL=http://nominatim:8080',
              secrets.NEXT_PUBLIC_STRIPE_PUBLIC_KEY) || '' }} \
            '${{ matrix.context }}'

      - name: Pousser dans le registre du lab
        run: |
          set -euo pipefail
          docker push '${{ vars.LAB_REGISTRY }}/${{ matrix.name }}:${{ steps.meta.outputs.tag }}'
```

⚠️ **Les `build-args` du frontend sont conservés mot pour mot.** Ils sont
gravés dans le bundle Next.js au build et ne sont pas relisables à
l'exécution : en omettre un remet les défauts de développement
(`127.0.0.1:10006`, `:4433`, `:4000`, `:8081`) dans l'image.

⚠️ La ligne `${{ matrix.context == 'front' && format(...) }}` est fragile à
relire. Si l'expression pose problème, la remplacer par un `if:` sur deux
étapes distinctes — une pour le frontend, une pour les deux autres — plutôt
que par une simplification qui perdrait un argument.

- [x] **Étape 4 : Déclarer la variable de dépôt**

Sur GitHub, `Settings → Secrets and variables → Actions → Variables` :

| Nom | Valeur |
|---|---|
| `LAB_REGISTRY` | `10.0.0.130:5000` (adresse relevée à la tâche 1) |

Une **variable** et non un secret : ce n'est pas une donnée sensible, et un
secret serait masqué dans les journaux, rendant tout diagnostic aveugle.

- [x] **Étape 5 : Relancer la vérification**

```bash
cd C:/Users/nbeny/Documents/GitHub/UrbanConnct
grep -c "ghcr.io" .github/workflows/ci.yml
```

Attendu : `0`.

Vérifier que les dix `build-args` sont toujours là :

```bash
grep -c "build-arg" .github/workflows/ci.yml
```

Attendu : `10`.

- [x] **Étape 6 : Valider la syntaxe du workflow**

```bash
cd C:/Users/nbeny/Documents/GitHub/UrbanConnct
python -c "import yaml,sys; yaml.safe_load(open('.github/workflows/ci.yml')); print('YAML valide')"
```

Attendu : `YAML valide`.

- [x] **Étape 7 : Commit**

```bash
git add .github/workflows/ci.yml
git commit -m "fix(ci): GHCR prive plafonne a 500 Mo, que le premier build depassait"
```

---

## Tâche 9 : Purger le registre en fin de build

**Files:**
- Create: `UrbanConnct/scripts/ci/registry-purge.sh`
- Modify: `UrbanConnct/.github/workflows/ci.yml` (job `images`)

- [x] **Étape 1 : Constater l'absence de rétention (l'échec attendu)**

```bash
ls C:/Users/nbeny/Documents/GitHub/UrbanConnct/scripts/ci/registry-purge.sh
```

Attendu : `No such file or directory`. Sans purge, trois images par livraison
s'empilent indéfiniment dans `/var/lib/lab-registry`.

- [x] **Étape 2 : Écrire le script**

Créer `UrbanConnct/scripts/ci/registry-purge.sh` :

```bash
#!/usr/bin/env bash
# Retention du registre du lab : garde les N derniers tags d'une image, purge
# le reste, puis libere l'espace.
#
# Usage : registry-purge.sh <registre> <image> [nb_a_garder]
#   registry-purge.sh 10.0.0.42:5000 urbanconnect-backend 10
#
# ⚠️ Tourne SUR ci-runner, ou vit le registre : aucun acces distant n'est
# necessaire. C'est ce qui rend cette purge preferable a un timer systemd --
# elle se declenche exactement quand quelque chose vient d'etre ajoute, et si
# la CI est a l'arret, rien ne s'accumule non plus.
set -euo pipefail

REGISTRY="${1:?registre attendu, ex. 10.0.0.42:5000}"
IMAGE="${2:?nom d'image attendu}"
KEEP="${3:-10}"
CONTAINER="${REGISTRY_CONTAINER:-lab-registry}"

# ⚠️ `tags/list` renvoie les tags dans un ordre NON specifie par la norme
# OCI -- en pratique alphabetique pour ce registre. Nos tags sont
# `sha-<abbrev>`, dont l'ordre alphabetique n'a AUCUN rapport avec l'ordre
# chronologique. On trie donc par date de creation, lue dans la configuration
# de chaque image, et non par nom.
tags=$(curl -sSf "http://${REGISTRY}/v2/${IMAGE}/tags/list" | jq -r '.tags // [] | .[]')

if [ -z "$tags" ]; then
  echo "Aucun tag pour ${IMAGE} — rien a purger."
  exit 0
fi

# Pour chaque tag : sa date de creation et son digest de manifeste.
dated=""
for tag in $tags; do
  digest=$(curl -sSI \
    -H 'Accept: application/vnd.docker.distribution.manifest.v2+json' \
    "http://${REGISTRY}/v2/${IMAGE}/manifests/${tag}" \
    | tr -d '\r' | awk -F': ' '/^[Dd]ocker-[Cc]ontent-[Dd]igest/{print $2}')
  [ -n "$digest" ] || continue

  cfg=$(curl -sSf \
    -H 'Accept: application/vnd.docker.distribution.manifest.v2+json' \
    "http://${REGISTRY}/v2/${IMAGE}/manifests/${tag}" | jq -r '.config.digest')
  created=$(curl -sSf \
    "http://${REGISTRY}/v2/${IMAGE}/blobs/${cfg}" | jq -r '.created')

  dated="${dated}${created}\t${tag}\t${digest}\n"
done

total=$(printf "%b" "$dated" | grep -c . || true)
echo "${IMAGE} : ${total} tag(s), on garde les ${KEEP} plus recents."

if [ "$total" -le "$KEEP" ]; then
  echo "Rien a supprimer."
  exit 0
fi

# Les plus recents en tete, on saute les KEEP premiers.
printf "%b" "$dated" | grep . | sort -r | tail -n "+$((KEEP + 1))" \
  | while IFS=$'\t' read -r created tag digest; do
      echo "  suppression ${tag} (${created})"
      # ⚠️ 202 est la reponse NORMALE d'une suppression acceptee. Un 405
      # signifie que REGISTRY_STORAGE_DELETE_ENABLED n'est pas pose sur le
      # registre : le script paraitrait alors fonctionner sans rien liberer.
      code=$(curl -sS -o /dev/null -w '%{http_code}' -X DELETE \
        "http://${REGISTRY}/v2/${IMAGE}/manifests/${digest}")
      case "$code" in
        202|404) ;;
        405) echo "::error::Le registre refuse les suppressions — REGISTRY_STORAGE_DELETE_ENABLED manque." ; exit 1 ;;
        *)   echo "::error::Suppression de ${tag} refusee (HTTP ${code})." ; exit 1 ;;
      esac
    done

# ⚠️ **CE SCRIPT NE LANCE PAS LE RAMASSE-MIETTES.** Supprimer un manifeste ne
# libere aucun octet -- les couches restent jusqu'a ce que `garbage-collect`
# passe -- mais ce dernier ne peut PAS tourner pendant un push : il supprime les
# blobs qu'il croit non references, y compris ceux d'un televersement en cours,
# ce qui corrompt l'image poussee. Or trois runners sont enregistres pour ce
# depot sur la meme VM, donc les trois images se poussent EN PARALLELE.
# Le ramasse-miettes vit donc dans un job distinct, apres la matrice.
echo "Manifestes supprimes. L'espace sera libere par le job registry-gc."
```

⚠️ La variable `CONTAINER` n'est plus utilisée par ce script — la retirer de
l'en-tête pour ne pas laisser croire qu'il parle au conteneur.

Le rendre exécutable :

```bash
chmod +x C:/Users/nbeny/Documents/GitHub/UrbanConnct/scripts/ci/registry-purge.sh
git update-index --chmod=+x scripts/ci/registry-purge.sh
```

- [x] **Étape 3 : Le brancher dans un job distinct, après la matrice**

⚠️ **Pas une étape du job `images`.** Trois runners sont enregistrés pour ce
dépôt sur `ci-runner` : les trois entrées de la matrice tournent en parallèle,
et un `registry garbage-collect` lancé pendant qu'une autre image se pousse
supprime des blobs en cours de téléversement. Le job ci-dessous ne démarre
qu'une fois les trois poussées terminées.

Ajouter, entre les jobs `images` et `deploy` :

```yaml
  registry-gc:
    name: Rétention du registre
    needs: images
    if: github.event_name == 'push' && github.ref == 'refs/heads/main'
    runs-on: [self-hosted, urbanlink]
    steps:
      - uses: actions/checkout@v4

      # Sequentiel, et c'est voulu : le ramasse-miettes ne doit croiser aucune
      # ecriture, pas meme une suppression de manifeste concurrente.
      - name: Supprimer les tags au-delà des 10 derniers
        run: |
          set -euo pipefail
          for img in urbanconnect-backend urbanconnect-frontend urbanconnect-temporal-worker; do
            ./scripts/ci/registry-purge.sh '${{ vars.LAB_REGISTRY }}' "$img" 10
          done

      # `--delete-untagged` supprime aussi les manifestes que plus aucun tag ne
      # designe -- ceux que l'etape precedente vient de detacher.
      - name: Libérer l'espace
        run: |
          set -euo pipefail
          docker exec lab-registry \
            registry garbage-collect --delete-untagged /etc/docker/registry/config.yml
          df -h /var/lib | tail -1
```

⚠️ **`deploy` ne doit PAS dépendre de ce job.** `needs: [images]` reste tel
quel : un échec de rétention ne doit jamais empêcher une livraison par ailleurs
valide de partir. Le disque a 58 Go libres — un tour de purge manqué n'est pas
un incident.

- [x] **Étape 4 : Vérifier que `jq` est présent sur le runner**

```bash
ssh -J root@192.168.100.50 debian@10.0.0.130 'command -v jq curl docker'
```

Attendu : trois chemins. Si `jq` manque :

```bash
ssh -J root@192.168.100.50 debian@10.0.0.130 'sudo apt-get install -y jq'
```

- [x] **Étape 5 : Tester le script à vide**

Sur une image qui n'existe pas, il doit sortir proprement :

```bash
ssh -J root@192.168.100.50 debian@10.0.0.130 \
  'cd /tmp && curl -sSf http://10.0.0.130:5000/v2/_catalog'
```

Attendu : un JSON listant le catalogue (`{"repositories":[...]}`), même vide.

- [x] **Étape 6 : Relancer la vérification de l'étape 1**

```bash
ls -l C:/Users/nbeny/Documents/GitHub/UrbanConnct/scripts/ci/registry-purge.sh
bash -n C:/Users/nbeny/Documents/GitHub/UrbanConnct/scripts/ci/registry-purge.sh
```

Attendu : le fichier existe, et `bash -n` ne renvoie rien (syntaxe valide).

- [x] **Étape 7 : Commit**

```bash
cd C:/Users/nbeny/Documents/GitHub/UrbanConnct
git add scripts/ci/registry-purge.sh .github/workflows/ci.yml
git commit -m "feat(ci): trois images par livraison s'empilaient sans jamais etre purgees"
```

---

## Tâche 10 : Étendre le job `deploy` à `config/`

**Files:**
- Create: `UrbanConnct/scripts/ci/check-config-declared.sh`
- Modify: `UrbanConnct/.github/workflows/ci.yml` (job `deploy`)
- Modify: `UrbanConnct/config/prod/kratos/kratos.yml` (en-tête)

- [x] **Étape 1 : Constater que `config/` ne part pas (l'échec attendu)**

```bash
cd C:/Users/nbeny/Documents/GitHub/UrbanConnct
grep -c "config/" .github/workflows/ci.yml
```

Attendu : `0` dans le job `deploy`. Le job n'écrit aujourd'hui que le tag des
images.

- [x] **Étape 2 : Écrire la garde**

Créer `UrbanConnct/scripts/ci/check-config-declared.sh` :

```bash
#!/usr/bin/env bash
# Verifie que tout fichier de config/ consomme par une ConfigMap est bien
# declare dans le configMapGenerator du depot d'infrastructure.
#
# Usage : check-config-declared.sh <chemin/vers/infra/kube/urbanlink>
#
# ⚠️ Sans cette garde, ajouter un fichier a config/common/kratos/ ne
# provoquerait AUCUNE erreur : il serait recopie dans infra, ignore par
# kustomize, et absent du cluster. La panne se manifesterait plus tard, sur un
# fichier introuvable a l'execution, sans lien visible avec l'ajout.
set -euo pipefail

KUSTOMIZE_DIR="${1:?chemin de kube/urbanlink attendu}"
KUSTOMIZATION="${KUSTOMIZE_DIR}/kustomization.yaml"
[ -f "$KUSTOMIZATION" ] || { echo "::error::${KUSTOMIZATION} introuvable." ; exit 1 ; }

# Les repertoires dont le CONTENU part dans une ConfigMap. Les autres
# (observability/, common/nominatim/) ne sont montes nulle part aujourd'hui --
# les inclure ferait echouer la garde sur des fichiers volontairement absents
# du cluster.
DIRS="
config/common/kratos
config/common/postgres-init
config/common/kibana
config/prod/kratos
config/prod/pgbouncer
config/prod/nominatim
"

# Documentation destinee aux humains, jamais montee. Les exclure explicitement
# plutot que de filtrer sur l'extension : un .md de donnees resterait detecte.
IGNORE_RE='^(README\.md|CLAUDE\.md)$'

manquants=0
for dir in $DIRS; do
  [ -d "$dir" ] || continue
  # -maxdepth 1 : `--from-file` ne recursait pas, et `files:` non plus. Les
  # sous-repertoires common/kratos/{email,email-templates,scripts} sont donc
  # hors sujet, pas oublies.
  while IFS= read -r f; do
    base=$(basename "$f")
    echo "$base" | grep -Eq "$IGNORE_RE" && continue
    if ! grep -qF "$f" "$KUSTOMIZATION"; then
      echo "::error file=${f}::${f} n'est declare dans aucun configMapGenerator de ${KUSTOMIZATION}. Ajoute-l'y, ou range-le dans un sous-repertoire s'il n'a pas a partir dans le cluster."
      manquants=$((manquants + 1))
    fi
  done < <(find "$dir" -maxdepth 1 -type f | sort)
done

if [ "$manquants" -gt 0 ]; then
  echo "::error::${manquants} fichier(s) de configuration non declare(s)."
  exit 1
fi
echo "Tous les fichiers de configuration sont declares."
```

```bash
chmod +x scripts/ci/check-config-declared.sh
git update-index --chmod=+x scripts/ci/check-config-declared.sh
```

- [x] **Étape 3 : Vérifier que la garde passe sur l'état actuel**

Elle doit être verte avant d'être branchée, sinon on ne saura pas distinguer un
vrai défaut d'une garde mal écrite.

```bash
cd C:/Users/nbeny/Documents/GitHub/UrbanConnct
./scripts/ci/check-config-declared.sh C:/Users/nbeny/Documents/GitHub/infra/kube/urbanlink
```

Attendu : `Tous les fichiers de configuration sont declares.`

- [x] **Étape 4 : Vérifier qu'elle attrape un ajout**

```bash
touch config/common/kratos/nouveau-fichier.json
./scripts/ci/check-config-declared.sh C:/Users/nbeny/Documents/GitHub/infra/kube/urbanlink
```

Attendu : code de retour `1` et un message nommant `nouveau-fichier.json`.

```bash
rm config/common/kratos/nouveau-fichier.json
```

- [x] **Étape 5 : Étendre le job `deploy`**

Dans `.github/workflows/ci.yml`, entre l'étape « Épingler les trois images » et
« Publier le bump » :

```yaml
      - name: Vérifier que toute la configuration est déclarée
        run: ./scripts/ci/check-config-declared.sh infra/kube/urbanlink

      # ⚠️ `--delete` est indispensable : sans lui, un fichier supprime du
      # depot applicatif survivrait indefiniment dans infra, et continuerait
      # d'etre monte dans le cluster. Le depot d'infrastructure cesserait de
      # decrire ce qui tourne.
      #
      # Seuls `common` et `prod` partent : `dev` n'a rien a faire sur ce
      # cluster, et l'y copier ferait croire qu'il y sert.
      - name: Recopier la configuration applicative
        run: |
          set -euo pipefail
          mkdir -p infra/kube/urbanlink/config
          # ⚠️ La documentation reste ici. CLAUDE.md et README.md ne sont montes
          # par rien (aucun configMapGenerator ne les liste) : les copier
          # n'ajouterait que du bruit dans le depot d'infrastructure. Et le
          # CLAUDE.md de kratos documente le format du bloc `providers` avec un
          # exemple contenant `GOCSPX-` et `apps.googleusercontent.com` -- de
          # quoi declencher pour rien la garde a secrets de ce depot-la.
          rsync -a --delete --exclude=CLAUDE.md --exclude=README.md \
            config/common/ infra/kube/urbanlink/config/common/
          rsync -a --delete --exclude=CLAUDE.md --exclude=README.md \
            config/prod/   infra/kube/urbanlink/config/prod/
```

Et modifier le message de commit de l'étape « Publier le bump » :

```yaml
          git commit -am "deploy: images ${{ needs.images.outputs.tag }} + config (${{ github.repository }}@${{ github.sha }})"
```

⚠️ L'étape « Publier le bump » teste `git diff --quiet` pour ne pas committer à
vide. Cette logique reste correcte : elle couvre maintenant deux sources de
changement au lieu d'une.

- [x] **Étape 6 : Modifier `kustomize edit set image` pour le registre local**

Dans l'étape « Épingler les trois images », remplacer la boucle :

```bash
          for img in backend frontend temporal-worker; do
            "$KUSTOMIZE" edit set image \
              "urbanconnect-$img=${{ vars.LAB_REGISTRY }}/urbanconnect-$img:$TAG"
          done
```

- [x] **Étape 7 : Documenter le couplage dans `kratos.yml`**

En tête de `config/prod/kratos/kratos.yml`, ajouter :

```yaml
# ⚠️ **CE FICHIER EST LE SEUL DE config/ QUI NE SE PROPAGE PAS ENTIEREMENT.**
#
# Son contenu part bien dans la ConfigMap `kratos-config` a chaque push sur
# main. Mais le bloc `selfservice.methods.oidc.config.providers` ci-dessous
# sert AUSSI de gabarit a la variable KRATOS_OIDC_PROVIDERS du Secret
# `urbanconnect-secrets` : le playbook 31-urbanlink-deploy.yml du depot infra
# lit cette structure et y injecte les vrais identifiants Google.
#
# ⇒ Modifier les FOURNISSEURS (en ajouter un, changer un `id`) exige de
#   rejouer `ansible-playbook playbooks/31-urbanlink-deploy.yml`. Le reste du
#   fichier, lui, se propage tout seul.
#
# ⚠️ Et l'oubli est MUET : Kratos demarre, tout fonctionne, seule la connexion
# du fournisseur concerne repond « Impossible d'initier la connexion ».
```

- [x] **Étape 8 : Relancer les vérifications**

```bash
cd C:/Users/nbeny/Documents/GitHub/UrbanConnct
python -c "import yaml; yaml.safe_load(open('.github/workflows/ci.yml')); print('YAML valide')"
bash -n scripts/ci/check-config-declared.sh
grep -c "rsync -a --delete" .github/workflows/ci.yml
grep -c "ghcr.io" .github/workflows/ci.yml
```

Attendu : `YAML valide`, rien pour `bash -n`, `2`, `0`.

- [x] **Étape 9 : Commit**

```bash
git add scripts/ci/check-config-declared.sh .github/workflows/ci.yml config/prod/kratos/kratos.yml
git commit -m "feat(ci): un changement dans config/ n'atteignait jamais le cluster"
```

---

## Tâche 11 : Bascule et vérification de bout en bout

**Files:** aucun — cette tâche exécute et observe.

⚠️ **L'ordre est imposé.** L'étape 4 avant l'étape 5 en particulier : `prune`
sur une Application dont la synchronisation échoue peut supprimer ce qu'elle
n'arrive pas à recréer.

- [x] **Étape 1 : Relever l'état de départ**

```bash
ssh -J root@192.168.100.50 nbeny@10.0.0.111 \
  'sudo kubectl -n urbanconnect get cm && \
   sudo kubectl -n argocd get application urbanlink \
     -o jsonpath="{.status.sync.status}/{.status.health.status}"'
```

Noter la liste des ConfigMaps (elles serviront à l'étape 6) et l'état d'Argo,
qui doit être `Synced/Healthy` avant de commencer.

- [x] **Étape 2 : Fusionner la branche `infra` sur `master`**

```bash
cd C:/Users/nbeny/Documents/GitHub/infra
git log origin/master..feat/livraison-continue --oneline
```

Vérifier que seuls les commits attendus figurent — le dépôt local est partagé
entre sessions, et un `push` envoie `HEAD`.

```bash
git checkout master && git merge --no-ff feat/livraison-continue && git push
```

- [x] **Étape 3 : Observer la première synchronisation**

```bash
ssh -J root@192.168.100.50 nbeny@10.0.0.111 \
  'sudo kubectl -n argocd patch application urbanlink --type merge \
     -p "{\"operation\":{\"sync\":{}}}" && \
   sudo kubectl -n argocd get application urbanlink -w'
```

Attendu : `Synced/Healthy`. Si `OutOfSync` persiste ou si l'état passe à
`Failed`, lire le détail avant d'aller plus loin :

```bash
ssh -J root@192.168.100.50 nbeny@10.0.0.111 \
  'sudo kubectl -n argocd get application urbanlink -o jsonpath="{.status.operationState.message}"'
```

⚠️ Le message `field is immutable` signifie qu'un Job a été oublié à la
tâche 5. Ne pas continuer.

- [x] **Étape 4 : Vérifier que les ConfigMaps hashées sont montées**

```bash
ssh -J root@192.168.100.50 nbeny@10.0.0.111 \
  'sudo kubectl -n urbanconnect get deploy kratos \
     -o jsonpath="{.spec.template.spec.volumes[*].configMap.name}"'
```

Attendu : un nom **avec** suffixe de hash (`kratos-config-…`). Un
`kratos-config` nu signifie qu'Argo sert encore l'ancienne définition.

- [x] **Étape 5 : Activer `prune`**

Seulement maintenant, et seulement si l'étape 3 a donné `Synced/Healthy`.

```bash
cd C:/Users/nbeny/Documents/GitHub/infra/ansible
ansible-playbook playbooks/32-argocd.yml -e pve_connection=ssh \
  -e argocd_ssh_key_file=/root/argocd_infra.key
```

Vérifier :

```bash
ssh -J root@192.168.100.50 nbeny@10.0.0.111 \
  'sudo kubectl -n argocd get application urbanlink \
     -o jsonpath="{.spec.syncPolicy.automated.prune}"'
```

Attendu : `true`.

- [x] **Étape 6 : Supprimer les ConfigMaps héritées d'Ansible**

Argo ne les a pas créées : `prune` ne les touchera jamais. Elles ne sont plus
montées par rien depuis l'étape 4.

```bash
ssh -J root@192.168.100.50 nbeny@10.0.0.111 \
  'sudo kubectl -n urbanconnect delete configmap \
     kratos-config postgres-init pgbouncer-config nominatim-config kibana-dashboards'
```

⚠️ **Supprimer les noms NUS uniquement.** Les versions hashées portent un
suffixe et sont celles qui servent. Vérifier immédiatement :

```bash
ssh -J root@192.168.100.50 nbeny@10.0.0.111 \
  'sudo kubectl -n urbanconnect get pods | grep -v Running | grep -v Completed'
```

Attendu : aucune ligne hormis l'en-tête.

- [x] **Étape 7 : Fusionner la branche applicative et déclencher la chaîne**

```bash
cd C:/Users/nbeny/Documents/GitHub/UrbanConnct
git checkout main && git merge --no-ff feat/ci-registry-locale && git push
```

- [x] **Étape 8 : Suivre la chaîne complète**

```bash
gh run watch --repo nbeny/UrbanConnct
```

Puis, dans l'ordre :

| Vérification | Commande | Attendu |
|---|---|---|
| Le registre a reçu | `curl http://10.0.0.130:5000/v2/urbanconnect-backend/tags/list` | le tag `sha-…` du commit |
| Le bump est arrivé | `cd infra && git fetch && git log origin/master -1 --oneline` | un commit `deploy: images sha-…` |
| Argo a réagi | `kubectl -n argocd get application urbanlink -o jsonpath='{.status.sync.status}/{.status.health.status}'` | `Synced/Healthy` |
| Les pods portent la bonne image | `kubectl -n urbanconnect get deploy backend -o jsonpath='{..image}'` | `10.0.0.130:5000/urbanconnect-backend:sha-…` |
| La migration a tourné avant | `kubectl -n urbanconnect get job backend-migrate -o jsonpath='{.status.succeeded}'` | `1` |

- [x] **Étape 9 : Vérifier qu'une variable se propage**

Le test qui valide la moitié config de la chaîne, et qu'aucune autre étape ne
couvre.

```bash
cd C:/Users/nbeny/Documents/GitHub/UrbanConnct
# Relever le nom monte AVANT
ssh -J root@192.168.100.50 nbeny@10.0.0.111 \
  'sudo kubectl -n urbanconnect get deploy pgbouncer -o jsonpath="{..configMapRef.name}"'

echo "# touche de verification $(date +%s)" >> config/prod/pgbouncer/pgbouncer.env
git commit -am "test(config): verifier la propagation d'une variable" && git push
```

Après la fin du workflow :

```bash
ssh -J root@192.168.100.50 nbeny@10.0.0.111 \
  'sudo kubectl -n urbanconnect get deploy pgbouncer -o jsonpath="{..configMapRef.name}"'
```

Attendu : un nom **différent** de celui relevé avant, et un pod `pgbouncer`
récemment redémarré.

```bash
git revert --no-edit HEAD && git push
```

- [x] **Étape 10 : Vérifier que la purge borne le registre**

Après quelques livraisons :

```bash
curl -s http://10.0.0.130:5000/v2/urbanconnect-backend/tags/list | jq '.tags | length'
```

Attendu : au plus `10`.

---

## Tâche 12 : Documenter la chaîne

**Files:**
- Modify: `infra/kube/README.md`
- Modify: `infra/README.md`
- Modify: `infra/ansible/playbooks/30-urbanlink-images.yml` (en-tête)

- [x] **Étape 1 : Constater le manque (l'échec attendu)**

```bash
cd C:/Users/nbeny/Documents/GitHub/infra
grep -ric "argo" README.md kube/README.md kube/urbanlink/README.md
```

Attendu : `0` partout. Aucun des trois READMEs ne mentionne Argo CD, alors
qu'il pilote tout le déploiement — un lecteur du dépôt ne peut pas deviner qui
fait quoi.

- [x] **Étape 2 : Écrire la section dans `kube/README.md`**

```markdown
## Livraison — qui fait quoi

Un `git push` sur `main` du dépôt applicatif suffit. Le partage des rôles :

| Ce qui change | Qui l'applique | Automatique |
|---|---|---|
| Code applicatif | CI → registre du lab → bump du tag dans ce dépôt → Argo CD | oui |
| Variables de `config/` | CI → copie dans `kube/urbanlink/config/` → `configMapGenerator` → Argo CD | oui |
| Manifests `kube/urbanlink/**` | Argo CD, sur push `master` | oui |
| Secret `urbanconnect-secrets` | `31-urbanlink-deploy.yml` | non — `secrets.env` n'est pas versionné |
| `AuthorizationPolicy` de la passerelle | `31-urbanlink-deploy.yml` | non — autre namespace |
| vhosts nginx du nœud PVE | `33-urbanlink-edge.yml` | non |

**Le redémarrage des pods est obtenu par le suffixe de hash du
`configMapGenerator`** : le nom de la ConfigMap dépend de son contenu, donc la
spec du Deployment change, donc les pods redémarrent. Modifier une ConfigMap
en place n'aurait provoqué aucun redémarrage.

**Les images vivent dans un registre local à la VM `ci-runner`**
(`ansible/roles/registry`), et non sur GHCR : le plan GitHub Free plafonne les
paquets privés à 500 Mo, que le premier build dépasse.

⚠️ **Un seul endroit où `config/` ne se propage pas entièrement** : le bloc
`providers` de `config/prod/kratos/kratos.yml` sert de gabarit à
`KRATOS_OIDC_PROVIDERS` du Secret. Changer les fournisseurs OIDC exige de
rejouer le playbook 31 — sinon Kratos démarre et seule la connexion Google
échoue.
```

- [x] **Étape 3 : Mettre à jour la section « Charges applicatives » du README racine**

Ajouter, après le paragraphe sur l'ingress :

```markdown
**Le déploiement est piloté par Argo CD**, qui suit `master` de ce dépôt et
réconcilie `kube/urbanlink/`. La CI du dépôt applicatif n'exécute aucun
`kubectl` sur les charges de travail : elle construit les images, les pousse
dans le registre du lab, et écrit ici le tag et la configuration. Détail du
partage des rôles dans [`kube/README.md`](kube/README.md).
```

- [x] **Étape 4 : Réécrire l'en-tête de `30-urbanlink-images.yml`**

Après la première ligne de description, ajouter :

```yaml
# ⚠️ **CE PLAYBOOK EST UN CHEMIN D'AMORCAGE, PLUS LE CHEMIN NORMAL.**
# Depuis le 2026-09-01, la CI du depot applicatif construit les images sur la
# VM ci-runner et les pousse dans le registre du lab ; Argo CD deploie le tag.
# Voir kube/README.md.
#
# Il reste utile pour : un premier demarrage avant que la CI n'ait tourne, un
# cluster reconstruit hors CI, ou un diagnostic ou l'on veut batir une image a
# la main. Les images qu'il produit portent le tag `prod` et vivent dans le
# containerd d'urbanlink, sans passer par le registre -- elles ne sont donc PAS
# celles qu'Argo epingle.
```

- [x] **Étape 5 : Relancer la vérification de l'étape 1**

```bash
cd C:/Users/nbeny/Documents/GitHub/infra
grep -ric "argo" README.md kube/README.md
```

Attendu : une valeur non nulle pour les deux.

- [x] **Étape 6 : Commit**

```bash
git add README.md kube/README.md ansible/playbooks/30-urbanlink-images.yml
git commit -m "docs(livraison): aucun README ne disait qui deploie, alors qu'Argo pilote tout"
```

---

## Revue du plan contre la spec

| Section de la spec | Tâche |
|---|---|
| § 2 — `ci-runner` non déclarée | 1 |
| § 5.1 — inventaire, groupe `ci_nodes` | 1 |
| § 5.2 — rôle `registry` | 2 |
| § 5.2 — `hosts.toml` et `config_path` containerd | 3 |
| § 5.3 — job `images` sans GHCR | 8 |
| § 5.3 — purge, 10 tags | 9 |
| § 5.4 — job `deploy`, `rsync` et garde | 10 |
| § 5.5 — `configMapGenerator` | 4 |
| § 5.6 — Jobs en hooks | 5 |
| § 5.7 — Ansible 31 allégé | 6 |
| § 5.7 — `prune: true` sur 32 | 7 |
| § 5.7 — en-tête de 30 | 12 |
| § 6 — couplage `KRATOS_OIDC_PROVIDERS` | 6 (playbook), 10 (fichier de config), 12 (README) |
| § 7 — ordre de bascule | 11 |
| § 9 — vérifications | 11, étapes 8 à 10 |

**Les valeurs de `ci-runner` ont été relevées le 2026-09-01** et substituées
partout dans le plan : IP `10.0.0.130`, utilisateur `debian` (déjà dans le
groupe `docker`), 58 Go libres sur 79, `jq`/`docker`/`curl`/`rsync` présents.

⚠️ **Un seul chemin d'accès fonctionne** : le rebond depuis le poste Windows,
`ssh -J root@192.168.100.50 debian@10.0.0.130`. Ni `qm guest exec` (la VM n'a
pas d'agent QEMU) ni un `ssh` lancé depuis le nœud PVE (sa clé RSA n'existe
plus) ne joignent cette machine.

⚠️ **Trois runners `UrbanConnct` tournent sur cette même VM.** La matrice du job
`images` bâtit donc les trois images en parallèle. C'est ce qui impose le job
`registry-gc` distinct de la tâche 9 : un ramasse-miettes concurrent d'un push
supprime des blobs en cours de téléversement.

---

## Exécution — 2026-09-01, ce que le plan n'avait pas prévu

Les douze tâches sont faites. Quatre écarts, tous mesurés sur la machine.

### 1. Le démon Docker de `ci-runner` refusait le registre qu'il héberge

Le plan annonçait « le push réussit (Docker traite les adresses IP privées comme
des registres non sécurisés par défaut) ». **C'est faux.** Docker 29.7.2 ne tient
pour non sécurisé que `127.0.0.0/8` ; `docker push 10.0.0.130:5000/alpine:test`
échoue sur `http: server gave HTTP response to HTTPS client` — **le message exact
du défaut containerd**, pour une cause distincte et un fichier différent. De quoi
croire que le correctif containerd n'a pas pris.

⇒ Le rôle `docker` gère désormais `insecure-registries` dans
`/etc/docker/daemon.json` (fusion, jamais écrasement : le fichier porte déjà la
rotation des journaux), et `35-ci-registry.yml` applique `docker` **avant**
`registry`. `docker_containerd_is_cri: false` sur `ci_nodes` évite d'y chercher
une section registry dans un `config.toml` que rien ne génère.

### 2. `20-debian-k8s.yml` n'avait pas de tags — désormais si

Rejouer le rôle `docker` sur `urbanlink` imposait de retraverser le rôle
`kubernetes`, donc kubeadm, sur une VM dont l'etcd fsync à 3,7 ms. Les trois
rôles portent leur nom en tag ; la garde de distribution est en `always`.

### 3. `git diff --quiet` puis `commit -am` ne voyaient pas un fichier NEUF

Le job `deploy` aurait annoncé « rien à publier » et rendu **0** sur un ajout de
configuration parfaitement réel — la panne la plus muette de toute la chaîne.
C'est `git add -A` puis `git diff --cached --quiet`.

### 4. La vérification du § 5 du plan (« une seule valeur ») est trop naïve

`kustomize build | grep -o "kratos-config[a-z0-9-]*" | sort -u` rend **deux**
valeurs, et c'est normal : `kratos-config` nu y est un **nom de volume**
(`volumes[].name`, `volumeMounts[].name`), pas une référence. La bonne
vérification énumère les `configMap.name` / `configMapRef.name` — faite en
cluster, elle rend les six noms hashés et rien d'autre.

### Fausse piste coûteuse, à ne pas refaire

Un `grep -c $'\r'` sous Git Bash **compte toutes les lignes** (le motif se réduit
à la chaîne vide) : de quoi conclure que tout `config/` est commité en CRLF, ce
qui aurait cassé `envs:` (`DB_HOST=postgres\r`). Mesure Python sur les blobs :
**LF partout, dans les deux dépôts.** Seule la copie de travail Windows est en
CRLF, et Argo lit le blob. Le commentaire de `.gitattributes` du dépôt
applicatif — « `config/` est commité en CRLF » — est faux, et c'est lui qui
lance sur cette piste.

### Ce qui bloquait vraiment le déclenchement

La porte `Backend (NestJS)` était rouge depuis le 2026-08-31 sur **7 tests**,
sans aucun rapport avec cette chaîne. Le plus grave : `PLATFORM_FEE_RATE`,
retiré de `stripe.constants.ts` par `7d57b9eb`, était toujours importé par
`scripts/dac7-backfill-core.ts` — hors du `tsconfig`, donc invisible à `tsc`.
La constante valait `undefined`, donc `NaN`, donc **toute pré-autorisation
partait en exception** dans le backfill DAC7. Corrigé sur la branche
`fix/porte-backend-rouge` du dépôt applicatif.
