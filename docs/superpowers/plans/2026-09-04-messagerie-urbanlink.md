# Messagerie `urbanlink.fr` — plan d'implémentation

> **Pour les agents :** SOUS-COMPÉTENCE REQUISE — utiliser `superpowers:subagent-driven-development`
> (recommandé) ou `superpowers:executing-plans` pour dérouler ce plan tâche par tâche.
> Les étapes sont en cases à cocher (`- [ ]`).

**But :** monter une messagerie complète pour `urbanlink.fr` — boîtes Mailcow sur une VM
du lab, courrier entrant et sortant par l'IP propre du VPS Hostinger — sans perdre un
seul mail et sans casser l'existant.

**Architecture :** le VPS `147.79.102.17` est un **routeur**, pas un relais SMTP : il
fait du DNAT `tcp/25` sans masquerade vers la VM à travers WireGuard, et du SNAT en
sortie. L'IP réelle des expéditeurs arrive donc intacte jusqu'à Rspamd, et Postfix parle
directement à Gmail et Outlook depuis une IP non listée. Les interfaces restent sur le
LAN, publiées par l'openresty du nœud comme les dix consoles existantes.

**Pile technique :** Terraform (VM), Ansible (tout le reste), WireGuard, Mailcow
(Postfix · Dovecot · Rspamd · SOGo), Cloudflare API, kube-prometheus-stack.

**Spec :** `docs/superpowers/specs/2026-09-04-messagerie-urbanlink-design.md`

---

## Rappels d'exécution valables pour TOUTES les tâches

**Le dépôt s'édite sur Windows, s'exécute sur le nœud.** Après toute modification de
`ansible/` ou `terraform/`, resynchroniser avant de jouer quoi que ce soit :

```bash
cd /c/Users/nbeny/Documents/GitHub/infra
tar -czf - --exclude=.git --exclude=mikrotik/secrets.env . \
  | ssh root@192.168.100.50 'mkdir -p /root/infra && tar -xzf - -C /root/infra'
```

⚠️ `tar` **écrase mais n'efface jamais**. Un fichier supprimé du dépôt survit sur le
nœud. Pour les répertoires entièrement gérés par git (`kube`, `mikrotik`, `scripts`,
`docs`), faire précéder d'un `rm -rf` côté nœud — **jamais** sur `ansible/` ni
`terraform/`, qui contiennent des fichiers propres au nœud (`inventory/20-terraform.yml`,
`terraform.tfvars`).

**Les playbooks se jouent depuis `/root/infra/ansible` sur le nœud**, qui est le seul
nœud de contrôle capable de joindre `10.0.0.0/24`.

**Adresses de référence :**

| | |
|---|---|
| Nœud Proxmox | `192.168.100.50` (`root`) |
| VM mail | `10.0.0.140`, VMID 140, utilisateur `nbeny` |
| VPS Hostinger | `147.79.102.17` (`root`), PTR `srv859050.hstgr.cloud` |
| Tunnel | `10.88.0.1` (VPS) ↔ `10.88.0.2` (VM), `udp/51820` |
| Réseau Docker Mailcow | `172.22.1.0/24` |

---

# PHASE 0 — Fondations

## Tâche 1 : Libérer 40 Go sur le VPS

**Fichiers :** aucun (opération ponctuelle, consignée dans le journal de la tâche).

- [ ] **Étape 1 : Relever l'état de départ**

```bash
ssh root@147.79.102.17 'df -h / ; docker system df ; docker ps --format "{{.Names}}"'
```

Attendu : `/` à **93 %**, `RECLAIMABLE` ≈ 30 Go d'images + 10 Go de cache, et
**exactement quatre conteneurs** : `folio-nbeny`, `francois-nbeny`,
`traefik-wzxc-traefik-1`, `crowdsec`.

- [ ] **Étape 2 : Purger le cache de build et les images orphelines**

```bash
ssh root@147.79.102.17 'docker builder prune -af && docker image prune -af'
```

`-a` sur `image prune` retire les images sans **conteneur** associé. Les quatre
conteneurs ci-dessus tiennent leurs images : elles ne sont pas candidates.

- [ ] **Étape 3 : Vérifier qu'on n'a rien cassé**

```bash
ssh root@147.79.102.17 'df -h / ; docker ps --format "{{.Names}}\t{{.Status}}"'
curl -sI https://nbeny.fr | head -1
curl -sI https://francois.nbeny.fr | head -1
```

Attendu : `/` sous **55 %**, les quatre conteneurs toujours `Up`, et deux
`HTTP/2 200`. **Si un site répond autre chose, s'arrêter et le signaler** — c'est la
production de l'utilisateur.

## Tâche 2 : Profil Terraform `debian-base` et VM `mail`

Le seul profil Debian existant est `debian-k8s`, qui clone le template 9100 (kubeadm,
kubelet, containerd réglé pour Kubernetes) et range la VM dans `debian_nodes` — groupe
auquel `site.yml` applique le rôle `kubernetes`. Une VM mail n'a rien à faire d'un
cluster. On ajoute donc un profil qui clone le socle nu 9000.

**Fichiers :**
- Modifier : `terraform/variables.tf` (map `templates`, validation des profils)
- Modifier : `terraform/main.tf` (locals, inventaire généré)
- Modifier : `terraform/terraform.tfvars` **sur le nœud** (non versionné)

- [ ] **Étape 1 : Déclarer le template du profil**

Dans `terraform/variables.tf`, remplacer le `default` de la variable `templates` :

```hcl
  default = {
    "debian-k8s"  = 9100
    "kali"        = 9101
    # Socle cloud-init nu : ni Docker ni Kubernetes. Docker est posé ensuite par
    # le role Ansible `docker`, ce qui evite de trainer kubeadm et un kubelet
    # sans cluster sur une machine qui n'en veut pas.
    "debian-base" = 9000
  }
```

- [ ] **Étape 2 : Autoriser le profil dans la validation**

Toujours dans `terraform/variables.tf`, la validation ligne ~101 :

```hcl
  validation {
    condition     = alltrue([for k, v in var.vms : contains(["debian-k8s", "debian-base", "kali"], v.profile)])
    error_message = "Chaque VM doit avoir un profile valant \"debian-k8s\", \"debian-base\" ou \"kali\"."
  }
```

- [ ] **Étape 3 : Séparer les VMs de base dans les locals**

Dans `terraform/main.tf`, après la ligne `kali_vms` :

```hcl
  debian_vms = { for k, v in var.vms : k => v if v.profile == "debian-k8s" }
  kali_vms   = { for k, v in var.vms : k => v if v.profile == "kali" }
  # Groupe DISTINCT de debian_nodes, et ce n'est pas une coquetterie : site.yml
  # applique le role `kubernetes` a debian_nodes. Y ranger la VM mail lui
  # installerait un plan de controle dont elle n'a que faire.
  base_vms = { for k, v in var.vms : k => v if v.profile == "debian-base" }
```

- [ ] **Étape 4 : Publier le nouveau groupe dans l'inventaire généré**

Dans le bloc `yamlencode` de `resource "local_file" "ansible_inventory"`, ajouter après
`kali_nodes` :

```hcl
      base_nodes = {
        hosts = { for k, v in local.base_vms : k => {
          ansible_host = v.ip
          vm_id        = v.vm_id
        } }
      }
```

- [ ] **Étape 5 : Synchroniser et déclarer la VM sur le nœud**

Synchroniser le dépôt (voir les rappels d'exécution), puis ajouter dans
`/root/infra/terraform/terraform.tfvars`, à l'intérieur du bloc `vms = {` :

```hcl
  # --- Messagerie urbanlink.fr ---------------------------------------------
  # BALLOONING ACTIF, contrairement aux VMs historiques en balloon: 0. Le noeud
  # promet deja 114 Go pour 110 Go physiques : cette VM rend sa memoire au
  # repos plutot que d'aggraver le surengagement.
  "mail" = {
    profile         = "debian-base"
    vm_id           = 140
    ip              = "10.0.0.140"
    cores           = 2
    memory          = 8192
    memory_floating = 4096
    disk_size       = 150
    on_boot         = true
    tags            = ["mail"]
    description     = "Mailcow -- boites urbanlink.fr. Emission via le VPS Hostinger."
  }
```

- [ ] **Étape 6 : Vérifier la RAM disponible AVANT d'appliquer**

```bash
ssh root@192.168.100.50 'free -g | head -2'
```

Attendu : au moins **10 Go disponibles** dans la colonne `available`. En dessous,
**s'arrêter** : la VM déclencherait l'OOM killer côté hôte, qui tuerait une VM sans
choisir laquelle.

- [ ] **Étape 7 : Appliquer**

```bash
ssh root@192.168.100.50 'cd /root/infra/terraform && terraform init -upgrade && terraform plan'
```

Attendu : `1 to add` (module.vm["mail"]), **0 to change, 0 to destroy**. Si le plan
propose de détruire quoi que ce soit, s'arrêter.

```bash
ssh root@192.168.100.50 'cd /root/infra/terraform && terraform apply -auto-approve'
```

- [ ] **Étape 8 : Vérifier la VM et l'inventaire**

```bash
ssh root@192.168.100.50 'qm list | grep 140'
ssh root@192.168.100.50 'grep -A4 base_nodes /root/infra/ansible/inventory/20-terraform.yml'
ssh -J root@192.168.100.50 nbeny@10.0.0.140 'hostname && ip -4 addr show | grep 10.0.0.140'
```

Attendu : VM `mail` `running`, groupe `base_nodes` contenant `mail`, et un SSH qui
répond.

- [ ] **Étape 9 : Commit**

```bash
git add terraform/variables.tf terraform/main.tf
git commit -m "feat(terraform): profil debian-base et groupe base_nodes pour la VM mail"
```

## Tâche 3 : Configuration de base de la VM et Docker

**Fichiers :**
- Créer : `ansible/inventory/group_vars/base_nodes.yml`
- Créer : `ansible/playbooks/40-mail-vm.yml`
- Modifier : `ansible/inventory/00-static.yml` (ajouter `base_nodes` sous `guests`)

- [ ] **Étape 1 : Variables du groupe**

`ansible/inventory/group_vars/base_nodes.yml` :

```yaml
---
# ============================================================================
#  VMs Debian nues : Docker, sans Kubernetes
# ============================================================================
# Groupe volontairement distinct de debian_nodes : celui-ci recoit le role
# `kubernetes` via site.yml, ce qui n'a aucun sens pour une messagerie.

docker_users:
  - "{{ lab_admin_user }}"
docker_compose_plugin: true
# Pas de cgroup driver systemd force : c'est une exigence de kubelet, absent ici.
docker_containerd_systemd_cgroup: false
```

- [ ] **Étape 2 : Rattacher le groupe au parapluie `guests`**

Dans `ansible/inventory/00-static.yml`, sous `guests: children:`, ajouter
`base_nodes:` à la suite de `ci_nodes:` — c'est ce qui fait entrer la VM dans
`90-update.yml` et `95-hardening.yml`.

- [ ] **Étape 3 : Le playbook**

`ansible/playbooks/40-mail-vm.yml` :

```yaml
---
# Socle de la VM de messagerie : compte admin, durcissement commun, Docker.
# Mailcow lui-meme est pose par 41-mailcow.yml.
#
#   ansible-playbook playbooks/40-mail-vm.yml

- name: Preparer la VM de messagerie
  hosts: base_nodes
  gather_facts: true
  become: true
  roles:
    - common
    - docker
```

- [ ] **Étape 4 : Jouer**

```bash
ssh root@192.168.100.50 'cd /root/infra/ansible && ansible-playbook playbooks/40-mail-vm.yml'
```

Attendu : `failed=0`.

- [ ] **Étape 4b : Activer le périphérique de l'agent QEMU**

Le rôle `common` installe `qemu-guest-agent`, mais **son service échoue à démarrer** :
le périphérique virtio-serial n'existe que si la VM a `agent: 1` côté Proxmox, or elle a
été créée avec `agent = false`. Un `reboot` depuis l'invité ne suffit pas — Proxmox
n'attache le matériel qu'au démarrage de la VM.

```bash
ssh root@192.168.100.50 'qm set 140 --agent enabled=1 && qm stop 140 && sleep 5 && qm start 140 && sleep 25 && qm agent 140 ping && echo AGENT-OK'
```

Puis **rejouer `40-mail-vm.yml`**, qui échouait sur cette tâche.

⚠️ Repasser ensuite `agent = true` dans `terraform.tfvars` et refaire un `apply` :
sans cela, le prochain passage de Terraform redésactiverait l'agent — donc le fsfreeze
de `vzdump`, donc la cohérence des sauvegardes.

- [ ] **Étape 5 : Vérifier, puis rejouer pour prouver l'idempotence**

```bash
ssh -J root@192.168.100.50 nbeny@10.0.0.140 'docker version --format "{{.Server.Version}}" && docker compose version'
ssh root@192.168.100.50 'cd /root/infra/ansible && ansible-playbook playbooks/40-mail-vm.yml' | tail -3
```

Attendu : une version de serveur Docker, une version de Compose, puis `changed=0` au
second passage.

- [ ] **Étape 6 : Commit**

```bash
git add ansible/inventory/group_vars/base_nodes.yml ansible/inventory/00-static.yml ansible/playbooks/40-mail-vm.yml
git commit -m "feat(ansible): socle Docker de la VM de messagerie"
```

## Tâche 4 : Déclarer le VPS dans l'inventaire

Le VPS devient une machine gérée : sa configuration doit être dans le dépôt, pas dans
l'historique d'un shell. Le nœud Proxmox est le nœud de contrôle, il lui faut donc un
accès SSH par clé.

**Fichiers :**
- Modifier : `ansible/inventory/00-static.yml` (groupe `edge_nodes`)
- Créer : `ansible/inventory/group_vars/edge_nodes.yml`

- [ ] **Étape 1 : Autoriser la clé du nœud sur le VPS**

```bash
PUB=$(ssh root@192.168.100.50 'cat /root/.ssh/id_ed25519.pub')
ssh root@147.79.102.17 "mkdir -p ~/.ssh && chmod 700 ~/.ssh && grep -qF '$PUB' ~/.ssh/authorized_keys 2>/dev/null || echo '$PUB' >> ~/.ssh/authorized_keys"
```

- [ ] **Étape 2 : Vérifier le chemin nœud → VPS**

```bash
ssh root@192.168.100.50 'ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new root@147.79.102.17 hostname'
```

Attendu : `nbeny`. Si `Permission denied`, la clé n'est pas la bonne — relire
`/root/.ssh/` du nœud, ne pas contourner en mot de passe.

- [ ] **Étape 3 : Déclarer le groupe**

Dans `ansible/inventory/00-static.yml`, après le groupe `ci_nodes` :

```yaml
    # VPS public Hostinger -- routeur de la messagerie (WireGuard + DNAT tcp/25).
    #
    # ⚠️ Il porte AUSSI trois sites en production (nbeny.fr, www.nbeny.fr,
    # francois.nbeny.fr) derriere Traefik, plus CrowdSec et un runner GitHub.
    # Aucun role joue ici ne doit toucher aux ports 80/443 ni au pare-feu de
    # Docker : les regles de la messagerie vivent dans le PostUp de wg0.
    #
    # ABSENT de `guests` a dessein : il n'est pas une VM du lab, et
    # 90-update.yml / 95-hardening.yml n'ont rien a y faire.
    edge_nodes:
      hosts:
        vps-mail:
          ansible_host: 147.79.102.17
          ansible_user: root
          ansible_connection: ssh
```

- [ ] **Étape 4 : Variables du groupe**

`ansible/inventory/group_vars/edge_nodes.yml` :

```yaml
---
# Le noeud de controle joint ce VPS par Internet, pas par le lab.
ansible_python_interpreter: /usr/bin/python3
```

- [ ] **Étape 5 : Vérifier**

```bash
ssh root@192.168.100.50 'cd /root/infra/ansible && ansible vps-mail -m ping'
```

Attendu : `"ping": "pong"`.

- [ ] **Étape 6 : Commit**

```bash
git add ansible/inventory/00-static.yml ansible/inventory/group_vars/edge_nodes.yml
git commit -m "feat(ansible): declarer le VPS Hostinger comme noeud de bord"
```

## Tâche 5 : Le tunnel WireGuard

**Fichiers :**
- Créer : `ansible/roles/mail_tunnel/defaults/main.yml`
- Créer : `ansible/roles/mail_tunnel/tasks/main.yml`
- Créer : `ansible/roles/mail_tunnel/tasks/vps.yml`
- Créer : `ansible/roles/mail_tunnel/tasks/mailvm.yml`
- Créer : `ansible/roles/mail_tunnel/templates/wg0-vps.conf.j2`
- Créer : `ansible/roles/mail_tunnel/templates/wg0-mail.conf.j2`
- Créer : `ansible/playbooks/41-mail-tunnel.yml`

- [ ] **Étape 1 : Les valeurs par défaut**

`ansible/roles/mail_tunnel/defaults/main.yml` :

```yaml
---
# ============================================================================
#  Tunnel WireGuard VPS <-> VM mail
# ----------------------------------------------------------------------------
#  Le VPS est un ROUTEUR, pas un relais SMTP. Il fait du DNAT tcp/25 SANS
#  masquerade : l'IP reelle de l'expediteur traverse le tunnel intacte, et
#  Rspamd peut donc appliquer SPF, DMARC et ses listes noires sur le vrai
#  client. Avec un relais SMTP, tous ces controles porteraient sur le VPS et
#  s'effondreraient.
# ============================================================================
mail_tunnel_port: 51820
mail_tunnel_vps_ip: 10.88.0.1
mail_tunnel_mail_ip: 10.88.0.2
mail_tunnel_subnet: 10.88.0.0/30

# IP publique du VPS -- c'est l'adresse d'emission de toute la messagerie.
mail_tunnel_public_ip: 147.79.102.17

# Reseau Docker de Mailcow (IPV4_NETWORK de mailcow.conf, suffixe .0/24).
# C'est le critere de routage cote VM : tout ce qui vient de la sort par le
# tunnel, dans les deux sens.
mail_tunnel_docker_net: 172.22.1.0/24

# Interface WAN du VPS, cible du DNAT et du SNAT.
mail_tunnel_vps_wan: eth0

mail_tunnel_keys_dir: /etc/wireguard
```

- [ ] **Étape 2 : Les tâches communes (génération des clés)**

`ansible/roles/mail_tunnel/tasks/main.yml` :

```yaml
---
- name: Installer WireGuard
  ansible.builtin.apt:
    name: [wireguard, wireguard-tools]
    state: present
    update_cache: true
    cache_valid_time: 3600

- name: Creer le repertoire des cles
  ansible.builtin.file:
    path: "{{ mail_tunnel_keys_dir }}"
    state: directory
    mode: "0700"

# La cle privee ne sort jamais de la machine qui la genere ; seule la publique
# est remontee comme fait pour etre posee sur le pair.
- name: Generer la cle privee si absente
  ansible.builtin.shell:
    cmd: "umask 077 && wg genkey > {{ mail_tunnel_keys_dir }}/privatekey"
    creates: "{{ mail_tunnel_keys_dir }}/privatekey"

- name: Lire la cle privee
  ansible.builtin.slurp:
    src: "{{ mail_tunnel_keys_dir }}/privatekey"
  register: mail_tunnel_priv
  no_log: true

- name: Deriver la cle publique
  ansible.builtin.shell:
    cmd: "wg pubkey < {{ mail_tunnel_keys_dir }}/privatekey"
  register: mail_tunnel_pub
  changed_when: false

- name: Memoriser les cles pour le pair
  ansible.builtin.set_fact:
    wg_private_key: "{{ mail_tunnel_priv.content | b64decode | trim }}"
    wg_public_key: "{{ mail_tunnel_pub.stdout | trim }}"
  no_log: true

- name: Configurer le cote VPS
  ansible.builtin.include_tasks: vps.yml
  when: inventory_hostname in groups['edge_nodes'] | default([])

- name: Configurer le cote VM mail
  ansible.builtin.include_tasks: mailvm.yml
  when: inventory_hostname in groups['base_nodes'] | default([])
```

- [ ] **Étape 3 : Le côté VPS**

`ansible/roles/mail_tunnel/templates/wg0-vps.conf.j2` :

```jinja
# Genere par Ansible (role mail_tunnel). Toute edition manuelle sera ecrasee.
[Interface]
Address = {{ mail_tunnel_vps_ip }}/30
ListenPort = {{ mail_tunnel_port }}
PrivateKey = {{ wg_private_key }}

# --- Publication du port 25 vers la VM, SANS masquerade ---------------------
# L'absence de MASQUERADE ici est LE point du design : elle preserve l'IP
# source de l'expediteur jusqu'a Rspamd.
PostUp = iptables -t nat -A PREROUTING -i {{ mail_tunnel_vps_wan }} -p tcp --dport 25 -j DNAT --to-destination {{ mail_tunnel_mail_ip }}:25
PostDown = iptables -t nat -D PREROUTING -i {{ mail_tunnel_vps_wan }} -p tcp --dport 25 -j DNAT --to-destination {{ mail_tunnel_mail_ip }}:25

# Docker impose FORWARD en politique DROP. DOCKER-USER est le point d'accroche
# officiel pour les regles maison : il est evalue en premier et survit aux
# redemarrages du demon, contrairement a un -A FORWARD.
PostUp = iptables -I DOCKER-USER -i {{ mail_tunnel_vps_wan }} -o wg0 -j ACCEPT
PostDown = iptables -D DOCKER-USER -i {{ mail_tunnel_vps_wan }} -o wg0 -j ACCEPT
PostUp = iptables -I DOCKER-USER -i wg0 -o {{ mail_tunnel_vps_wan }} -j ACCEPT
PostDown = iptables -D DOCKER-USER -i wg0 -o {{ mail_tunnel_vps_wan }} -j ACCEPT

# --- Sortie : c'est ici que la messagerie prend l'IP propre du VPS ----------
PostUp = iptables -t nat -A POSTROUTING -s {{ mail_tunnel_subnet }} -o {{ mail_tunnel_vps_wan }} -j MASQUERADE
PostDown = iptables -t nat -D POSTROUTING -s {{ mail_tunnel_subnet }} -o {{ mail_tunnel_vps_wan }} -j MASQUERADE

[Peer]
# VM mail
PublicKey = {{ hostvars['mail'].wg_public_key }}
AllowedIPs = {{ mail_tunnel_mail_ip }}/32
PersistentKeepalive = 25
```

`ansible/roles/mail_tunnel/tasks/vps.yml` :

```yaml
---
- name: Activer le routage IPv4
  ansible.posix.sysctl:
    name: net.ipv4.ip_forward
    value: "1"
    sysctl_set: true
    state: present
    reload: true

# rp_filter strict jetterait SILENCIEUSEMENT les paquets entrants arrivant par
# wg0 dont la source est une IP Internet : la route vers cette source passe par
# eth0. C'est exactement le genre de panne qui ne laisse aucune trace.
- name: Assouplir rp_filter sur le tunnel
  ansible.posix.sysctl:
    name: "{{ item }}"
    value: "2"
    sysctl_set: true
    state: present
    reload: true
  loop:
    - net.ipv4.conf.all.rp_filter
    - net.ipv4.conf.default.rp_filter

- name: Deposer la configuration du tunnel
  ansible.builtin.template:
    src: wg0-vps.conf.j2
    dest: /etc/wireguard/wg0.conf
    mode: "0600"
  notify: Redemarrer wireguard

- name: Activer le tunnel
  ansible.builtin.systemd_service:
    name: wg-quick@wg0
    enabled: true
    state: started
```

`ansible/roles/mail_tunnel/handlers/main.yml` :

```yaml
---
- name: Redemarrer wireguard
  ansible.builtin.systemd_service:
    name: wg-quick@wg0
    state: restarted
    daemon_reload: true
```

- [ ] **Étape 4 : Le côté VM**

`ansible/roles/mail_tunnel/templates/wg0-mail.conf.j2` :

```jinja
# Genere par Ansible (role mail_tunnel). Toute edition manuelle sera ecrasee.
[Interface]
Address = {{ mail_tunnel_mail_ip }}/30
PrivateKey = {{ wg_private_key }}

# --- Routage du SEUL reseau Docker de Mailcow par le tunnel -----------------
# Le critere est le RESEAU, pas le port, et ce n'est pas un raccourci :
#   * Postfix tourne dans un conteneur -> son trafic passe par FORWARD, jamais
#     par OUTPUT. Un marquage `-t mangle -A OUTPUT --dport 25` n'attraperait
#     rien du tout.
#   * Pour une connexion ENTRANTE DNATee, la traduction inverse du paquet de
#     reponse n'a lieu qu'en POSTROUTING : au moment du routage, la reponse
#     porte encore l'adresse du conteneur. Une regle `from 10.88.0.2` ne
#     matcherait jamais et les reponses partiraient par la passerelle du lab.
# Router tout le reseau Docker regle les deux sens d'un coup.
#
# La VM elle-meme garde sa route par defaut vers le lab : elle reste joignable,
# a jour et administrable meme tunnel coupe.
PostUp = ip rule add from {{ mail_tunnel_docker_net }} lookup 100 pref 100
PostDown = ip rule del from {{ mail_tunnel_docker_net }} lookup 100 pref 100
PostUp = ip route add default via {{ mail_tunnel_vps_ip }} dev wg0 table 100
PostDown = ip route del default via {{ mail_tunnel_vps_ip }} dev wg0 table 100

# Le pair n'accepte que 10.88.0.2 dans ses AllowedIPs : sans ce SNAT, les
# paquets partiraient en 172.22.1.x et seraient refuses par WireGuard.
PostUp = iptables -t nat -A POSTROUTING -s {{ mail_tunnel_docker_net }} -o wg0 -j SNAT --to-source {{ mail_tunnel_mail_ip }}
PostDown = iptables -t nat -D POSTROUTING -s {{ mail_tunnel_docker_net }} -o wg0 -j SNAT --to-source {{ mail_tunnel_mail_ip }}

[Peer]
# VPS Hostinger
PublicKey = {{ hostvars['vps-mail'].wg_public_key }}
Endpoint = {{ mail_tunnel_public_ip }}:{{ mail_tunnel_port }}
AllowedIPs = {{ mail_tunnel_vps_ip }}/32
PersistentKeepalive = 25
```

`ansible/roles/mail_tunnel/tasks/mailvm.yml` :

```yaml
---
- name: Activer le routage IPv4
  ansible.posix.sysctl:
    name: net.ipv4.ip_forward
    value: "1"
    sysctl_set: true
    state: present
    reload: true

- name: Assouplir rp_filter
  ansible.posix.sysctl:
    name: "{{ item }}"
    value: "2"
    sysctl_set: true
    state: present
    reload: true
  loop:
    - net.ipv4.conf.all.rp_filter
    - net.ipv4.conf.default.rp_filter

- name: Deposer la configuration du tunnel
  ansible.builtin.template:
    src: wg0-mail.conf.j2
    dest: /etc/wireguard/wg0.conf
    mode: "0600"
  notify: Redemarrer wireguard

- name: Activer le tunnel
  ansible.builtin.systemd_service:
    name: wg-quick@wg0
    enabled: true
    state: started
```

- [ ] **Étape 5 : Le playbook**

`ansible/playbooks/41-mail-tunnel.yml` :

```yaml
---
# Tunnel WireGuard entre le VPS Hostinger et la VM mail.
#
# Les deux hotes sont dans le MEME play : chacun a besoin de la cle publique de
# l'autre, et `hostvars` ne la porte que si les deux ont ete traites dans la
# meme execution. Jouer -l sur un seul hote echouerait sur une cle absente.
#
#   ansible-playbook playbooks/41-mail-tunnel.yml

- name: Monter le tunnel de la messagerie
  hosts: edge_nodes:base_nodes
  gather_facts: true
  become: true
  roles:
    - mail_tunnel
```

⚠️ L'ordre compte : le rôle calcule d'abord les clés des deux hôtes (tâches communes),
puis écrit les configurations. Ansible traite les tâches hôte par hôte en parallèle,
donc `hostvars[...].wg_public_key` est disponible au moment des templates.

- [ ] **Étape 6 : Jouer et vérifier la poignée de main**

```bash
ssh root@192.168.100.50 'cd /root/infra/ansible && ansible-playbook playbooks/41-mail-tunnel.yml'
ssh root@147.79.102.17 'wg show'
ssh -J root@192.168.100.50 nbeny@10.0.0.140 'sudo wg show && ping -c3 10.88.0.1'
```

Attendu : `latest handshake` renseigné des deux côtés, `transfer` non nul, et
3 réponses au ping.

- [ ] **Étape 7 : Vérifier que les sites du VPS n'ont pas bougé**

```bash
curl -sI https://nbeny.fr | head -1 ; curl -sI https://francois.nbeny.fr | head -1
```

Attendu : deux `HTTP/2 200`. Les règles `DOCKER-USER` ne touchent que `wg0`.

- [ ] **Étape 8 : Commit**

```bash
git add ansible/roles/mail_tunnel ansible/playbooks/41-mail-tunnel.yml
git commit -m "feat(ansible): tunnel WireGuard VPS <-> VM mail, VPS en routeur"
```

## Tâche 6 : Prouver que le port 25 entrant traverse la chaîne

Avant d'installer quoi que ce soit, on vérifie que le chemin
`Internet → VPS → tunnel → VM` fonctionne. Un simple `nc` en écoute sur la VM suffit.

- [ ] **Étape 1 : Mettre une oreille sur le port 25 de la VM**

```bash
ssh -J root@192.168.100.50 nbeny@10.0.0.140 'sudo timeout 60 nc -l -p 25 -v'
```

Laisser tourner dans un terminal.

- [ ] **Étape 2 : Frapper depuis Internet, dans un autre terminal**

Depuis le poste Windows — le trafic sort par la box, fait le tour d'Internet et
revient sur le VPS, c'est donc un vrai test externe :

```bash
timeout 10 bash -c 'exec 3<>/dev/tcp/147.79.102.17/25 && echo "EHLO test" >&3'
```

Attendu, côté VM : `connect to [10.88.0.2] from ...` **avec l'IP publique de la
maison `82.65.87.60`**, pas `10.88.0.1`. C'est la preuve que le DNAT préserve la source
— tout le design en dépend.

**Si l'IP affichée est `10.88.0.1`**, une règle de masquerade s'est glissée sur le VPS :
relire `iptables -t nat -L POSTROUTING -n` et corriger avant d'aller plus loin.

**Si RIEN n'arrive**, deux causes possibles, toutes deux rencontrées le 2026-09-05 et
corrigées dans le rôle — les vérifier dans cet ordre :

1. **Le compteur DNAT du VPS monte, la VM ne voit rien.** WireGuard filtre les paquets
   *entrants* sur leur adresse **source** (cryptokey routing) : avec
   `AllowedIPs = 10.88.0.1/32`, un paquet venant d'une IP Internet est jeté en silence.
   Il faut `AllowedIPs = 0.0.0.0/0` **et** `Table = off` côté VM — sans `Table = off`,
   wg-quick installerait une route par défaut vers le tunnel et la VM deviendrait
   inadministrable.

   ```bash
   ssh root@147.79.102.17 'iptables -t nat -L PREROUTING -n -v | grep dpt:25'
   ssh -J root@192.168.100.50 nbeny@10.0.0.140 'sudo timeout 20 tcpdump -ni wg0 tcp port 25'
   ```

2. **Les SYN arrivent sur `wg0`, aucune réponse ne repart.** La réponse est sourcée en
   `10.88.0.2` et repart par la passerelle du lab. Il manque
   `ip rule add from 10.88.0.2 lookup 100`. Symptôme caractéristique : l'émetteur ne
   reçoit **rien du tout**, pas même un RST.

- [ ] **Étape 3 : Consigner le résultat**

Noter dans le journal de la tâche l'IP source observée. Aucun commit.

## Tâche 7 : rDNS et enregistrement `mail.urbanlink.fr`

- [ ] **Étape 1 : ACTION UTILISATEUR — le rDNS**

Dans le hPanel Hostinger : **VPS → Paramètres → Adresse IP → rDNS**, mettre
`mail.urbanlink.fr` pour `147.79.102.17`.

Ne pas continuer la tâche tant que ce n'est pas fait : l'ordre importe, le PTR doit
exister avant que le nom ne serve de HELO.

- [ ] **Étape 2 : Poser l'enregistrement A**

À faire dans le tableau de bord Cloudflare, zone `urbanlink.fr` :
`mail` → `A` → `147.79.102.17` → **nuage GRIS (DNS only)** → TTL Auto.

⚠️ Le nuage orange casserait tout : Cloudflare ne proxifie pas le SMTP, et le nom
résoudrait vers une IP Cloudflare qui n'écoute pas sur le port 25.

- [ ] **Étape 3 : Vérifier la cohérence PTR ↔ A**

```bash
dig +short A mail.urbanlink.fr @1.1.1.1
dig +short -x 147.79.102.17 @1.1.1.1
```

Attendu : `147.79.102.17` puis `mail.urbanlink.fr.` — la boucle est fermée, c'est le
FCrDNS qu'exigent Gmail et Outlook.

---

# PHASE 1 — Mailcow

## Tâche 8 : Installer Mailcow sur la VM

**Fichiers :**
- Créer : `ansible/roles/mailcow/defaults/main.yml`
- Créer : `ansible/roles/mailcow/tasks/main.yml`
- Créer : `ansible/roles/mailcow/templates/mailcow.conf.j2`
- Créer : `ansible/playbooks/42-mailcow.yml`

- [ ] **Étape 1 : Les valeurs par défaut**

`ansible/roles/mailcow/defaults/main.yml` :

```yaml
---
# ============================================================================
#  Mailcow -- boites urbanlink.fr
# ============================================================================
mailcow_dir: /opt/mailcow-dockerized
mailcow_repo: https://github.com/mailcow/mailcow-dockerized.git

# Identite SMTP : c'est ce nom qui est annonce en HELO et qui doit correspondre
# au PTR de 147.79.102.17. Il resout PUBLIQUEMENT vers le VPS.
mailcow_hostname: mail.urbanlink.fr

# Nom des INTERFACES, distinct du precedent. Couvert par le wildcard
# *.urbanlink.fr -> 192.168.100.50, donc LAN uniquement. Sans cette entree,
# le nginx de Mailcow rejetterait l'en-tete Host du vhost interne.
mailcow_ui_hostname: webmail.urbanlink.fr

mailcow_timezone: Europe/Paris

# Reseau Docker : doit rester coherent avec mail_tunnel_docker_net, qui est le
# critere de routage du tunnel. Les changer separement casse l'emission.
mailcow_ipv4_network: 172.22.1

# ClamAV et Solr couteraient 2 Go de RAM pour un volume de courrier personnel.
# Rspamd fait deja le gros du filtrage.
mailcow_skip_clamd: "y"
mailcow_skip_solr: "y"
```

- [ ] **Étape 2 : Le gabarit de configuration**

`ansible/roles/mailcow/templates/mailcow.conf.j2` — partir du `generate_config.sh` de
Mailcow puis figer les valeurs qui comptent :

```jinja
# Genere par Ansible (role mailcow). Les secrets (DBPASS, DBROOT) sont
# CONSERVES d'une execution a l'autre : les regenerer rendrait la base
# inaccessible et perdrait toutes les boites.
MAILCOW_HOSTNAME={{ mailcow_hostname }}
ADDITIONAL_SERVER_NAMES={{ mailcow_ui_hostname }}
MAILCOW_PASS_SCHEME=BLF-CRYPT
DBNAME=mailcow
DBUSER=mailcow
DBPASS={{ mailcow_dbpass }}
DBROOT={{ mailcow_dbroot }}

# L'UI ne prend pas 80/443 : elle est servie par l'openresty du noeud, qui
# termine le TLS avec le certificat wildcard.
HTTP_PORT=8080
HTTP_BIND=0.0.0.0
HTTPS_PORT=8443
HTTPS_BIND=0.0.0.0

SMTP_PORT=25
SMTPS_PORT=465
SUBMISSION_PORT=587
IMAP_PORT=143
IMAPS_PORT=993
SIEVE_PORT=4190
DOVEADM_PORT=127.0.0.1:19991

TZ={{ mailcow_timezone }}
COMPOSE_PROJECT_NAME=mailcowdockerized
DOCKER_COMPOSE_VERSION=native

# Certificats fournis par le noeud (wildcard *.urbanlink.fr, DNS-01
# Cloudflare). Un ACME local echouerait : le port 80 du nom public appartient
# au VPS, pas a cette VM.
SKIP_LETS_ENCRYPT=y
SKIP_IP_CHECK=y
SKIP_HTTP_VERIFICATION=y
SKIP_CLAMD={{ mailcow_skip_clamd }}
SKIP_SOLR={{ mailcow_skip_solr }}
SKIP_SOGO=n

IPV4_NETWORK={{ mailcow_ipv4_network }}
IPV6_NETWORK=fd4d:6169:6c63:6f77::/64
# IPv6 DESACTIVE, et c'est deliberе : le VPS prefere sa route v6, or emettre en
# IPv6 sans PTR ni SPF alignes sur 2a02:4780:28:981f::1 vaut un rejet sec chez
# Gmail. Le tunnel est en v4 seul.
ENABLE_IPV6=false

WATCHDOG_NOTIFY_EMAIL=
MAILDIR_GC_TIME=7200
ACL_ANYONE=disallow
```

- [ ] **Étape 3 : Les tâches**

`ansible/roles/mailcow/tasks/main.yml` :

```yaml
---
- name: Cloner Mailcow
  ansible.builtin.git:
    repo: "{{ mailcow_repo }}"
    dest: "{{ mailcow_dir }}"
    version: master
    depth: 1
    update: false          # une mise a jour se fait par ./update.sh, pas ici

- name: Verifier si une configuration existe deja
  ansible.builtin.stat:
    path: "{{ mailcow_dir }}/mailcow.conf"
  register: mailcow_conf_stat

# Les mots de passe de base ne sont generes QU'AU PREMIER PASSAGE puis relus.
# Les regenerer a chaque execution rendrait MySQL inaccessible et perdrait
# toutes les boites -- c'est le piege classique de ce genre de role.
- name: Relire les secrets existants
  ansible.builtin.shell:
    cmd: "grep -E '^{{ item.key }}=' {{ mailcow_dir }}/mailcow.conf | cut -d= -f2-"
  register: mailcow_existing
  changed_when: false
  loop:
    - { key: DBPASS }
    - { key: DBROOT }
  when: mailcow_conf_stat.stat.exists

- name: Fixer les secrets de base
  ansible.builtin.set_fact:
    mailcow_dbpass: >-
      {{ (mailcow_existing.results[0].stdout | default('') | trim)
         or lookup('password', '/dev/null length=28 chars=ascii_letters,digits') }}
    mailcow_dbroot: >-
      {{ (mailcow_existing.results[1].stdout | default('') | trim)
         or lookup('password', '/dev/null length=28 chars=ascii_letters,digits') }}
  no_log: true

- name: Deposer mailcow.conf
  ansible.builtin.template:
    src: mailcow.conf.j2
    dest: "{{ mailcow_dir }}/mailcow.conf"
    mode: "0600"

- name: Demarrer la pile
  ansible.builtin.command:
    cmd: docker compose up -d
    chdir: "{{ mailcow_dir }}"
  register: mailcow_up
  changed_when: "'Started' in mailcow_up.stderr or 'Created' in mailcow_up.stderr"

- name: Attendre que l'UI reponde
  ansible.builtin.uri:
    url: "http://127.0.0.1:8080/"
    status_code: [200, 301, 302]
  register: mailcow_ui
  retries: 30
  delay: 10
  until: mailcow_ui is succeeded
```

- [ ] **Étape 4 : Le playbook**

`ansible/playbooks/42-mailcow.yml` :

```yaml
---
# Installe Mailcow sur la VM de messagerie.
#
# Prerequis :
#   1. 40-mail-vm.yml  -> Docker present
#   2. 41-mail-tunnel.yml -> le tunnel porte deja le trafic
#
#   ansible-playbook playbooks/42-mailcow.yml

- name: Installer Mailcow
  hosts: base_nodes
  gather_facts: true
  become: true
  roles:
    - mailcow
```

- [ ] **Étape 5 : Jouer et vérifier**

```bash
ssh root@192.168.100.50 'cd /root/infra/ansible && ansible-playbook playbooks/42-mailcow.yml'
ssh -J root@192.168.100.50 nbeny@10.0.0.140 'cd /opt/mailcow-dockerized && sudo docker compose ps --format "{{.Service}} {{.State}}" | sort'
```

Attendu : tous les services en `running`, aucun `restarting`.

- [ ] **Étape 6 : Vérifier que le réseau Docker correspond au tunnel**

```bash
ssh -J root@192.168.100.50 nbeny@10.0.0.140 'sudo docker network inspect mailcowdockerized_mailcow-network -f "{{range .IPAM.Config}}{{.Subnet}}{{end}}"'
```

Attendu : `172.22.1.0/24`. **Toute autre valeur casse l'émission** : le tunnel ne
route que ce préfixe. Corriger `mail_tunnel_docker_net` et rejouer la tâche 5.

- [ ] **Étape 7 : Commit**

```bash
git add ansible/roles/mailcow ansible/playbooks/42-mailcow.yml
git commit -m "feat(ansible): Mailcow sur la VM de messagerie"
```

## Tâche 9 : Distribuer le certificat wildcard à la VM

Le nœud détient déjà `*.urbanlink.fr` (rôle `tls_certificates`, DNS-01 Cloudflare) :
il couvre `mail.urbanlink.fr` **et** `webmail.urbanlink.fr`. Émettre un second
certificat depuis la VM demanderait d'y recopier le token Cloudflare pour rien.

**Fichiers :**
- Créer : `ansible/roles/mailcow/tasks/certificates.yml`
- Créer : `ansible/roles/mailcow/files/deploy-mail-cert.sh`
- Modifier : `ansible/roles/tls_certificates/defaults/main.yml` (hook de déploiement)

- [ ] **Étape 1 : Le script de distribution, posé sur le nœud**

`ansible/roles/mailcow/files/deploy-mail-cert.sh` :

```bash
#!/bin/bash
# Recopie le certificat wildcard *.urbanlink.fr du noeud vers la VM Mailcow,
# puis recharge les services qui le presentent.
#
# Appele par le --deploy-hook de certbot : il ne tourne QUE si le certificat a
# reellement ete renouvele.
set -euo pipefail

SRC=/etc/letsencrypt/live/urbanlink.fr
VM=10.0.0.140
DEST=/opt/mailcow-dockerized/data/assets/ssl

ssh -o BatchMode=yes "nbeny@${VM}" "sudo mkdir -p ${DEST}"
scp -o BatchMode=yes "${SRC}/fullchain.pem" "nbeny@${VM}:/tmp/cert.pem"
scp -o BatchMode=yes "${SRC}/privkey.pem"   "nbeny@${VM}:/tmp/key.pem"
ssh -o BatchMode=yes "nbeny@${VM}" "sudo install -m 644 /tmp/cert.pem ${DEST}/cert.pem \
  && sudo install -m 600 /tmp/key.pem ${DEST}/key.pem \
  && rm -f /tmp/cert.pem /tmp/key.pem \
  && cd /opt/mailcow-dockerized \
  && sudo docker compose restart postfix-mailcow dovecot-mailcow nginx-mailcow"
```

- [ ] **Étape 2 : Les tâches**

`ansible/roles/mailcow/tasks/certificates.yml` (à inclure depuis `main.yml` avec
`delegate_to` sur le nœud) :

```yaml
---
- name: Deposer le script de distribution sur le noeud
  ansible.builtin.copy:
    src: deploy-mail-cert.sh
    dest: /usr/local/sbin/deploy-mail-cert.sh
    mode: "0750"
  delegate_to: pve

- name: Distribuer le certificat immediatement
  ansible.builtin.command:
    cmd: /usr/local/sbin/deploy-mail-cert.sh
  delegate_to: pve
  changed_when: true
```

Ajouter en fin de `ansible/roles/mailcow/tasks/main.yml` :

```yaml
- name: Poser le certificat
  ansible.builtin.include_tasks: certificates.yml
```

- [ ] **Étape 3 : Chaîner sur le renouvellement**

Dans `ansible/roles/tls_certificates/defaults/main.yml`, remplacer le hook :

```yaml
# Le hook recharge l'openresty ET redistribue le wildcard a la VM Mailcow.
# Sans le second membre, Postfix continuerait de presenter un certificat
# expire au bout de 90 jours -- panne silencieuse et tardive, la pire espece.
tls_certificates_deploy_hook: "systemctl reload openresty && /usr/local/sbin/deploy-mail-cert.sh"
```

⚠️ Rejouer `32-tls-certificates.yml` après ce changement, sinon le hook enregistré dans
`/etc/letsencrypt/renewal/urbanlink.fr.conf` reste l'ancien.

- [ ] **Étape 4 : Vérifier le certificat servi par Postfix**

```bash
ssh -J root@192.168.100.50 nbeny@10.0.0.140 \
  'echo QUIT | openssl s_client -starttls smtp -connect 127.0.0.1:25 -servername mail.urbanlink.fr 2>/dev/null | openssl x509 -noout -subject -dates'
```

Attendu : un sujet couvrant `*.urbanlink.fr` et une date d'expiration dans ~90 jours.

- [ ] **Étape 5 : Commit**

```bash
git add ansible/roles/mailcow ansible/roles/tls_certificates/defaults/main.yml
git commit -m "feat(mailcow): distribuer le wildcard du noeud et le rechainer sur le renouvellement"
```

## Tâche 10 : Publier les interfaces en interne

**Fichiers :**
- Modifier : `ansible/roles/edge_urbanlink/defaults/main.yml`

- [ ] **Étape 1 : Déclarer le service**

Dans `edge_urbanlink_services`, section « consoles d'administration : LAN UNIQUEMENT »,
ajouter :

```yaml
  # Interfaces de la messagerie : Mailcow (admin, quarantaine, DKIM), SOGo
  # (webmail) et Rspamd, toutes servies par le nginx de Mailcow sur la VM 140.
  #
  # ATTENTION -- le nom est `webmail`, PAS `mail`. `mail.urbanlink.fr` est
  # l'identite SMTP publique : elle resout vers le VPS. Publier l'UI dessus la
  # rendrait injoignable depuis le LAN, et surtout impossible a proteger.
  # Aucun `public: true` : cette console vaut un acces total au courrier.
  - name: webmail
    hosts: ["webmail.urbanlink.fr"]
    upstream: "http://10.0.0.140:8080"
    max_body: 0                 # pieces jointes
    read_timeout: 300s
```

- [ ] **Étape 2 : Jouer**

```bash
ssh root@192.168.100.50 'cd /root/infra/ansible && ansible-playbook playbooks/33-urbanlink-edge.yml'
```

Attendu : `failed=0`, et l'assertion finale « Wildcard `*.urbanlink.fr` intact » en
`ok`.

- [ ] **Étape 3 : Vérifier depuis le LAN et vérifier l'étanchéité**

Depuis le poste Windows :

```bash
curl -sI https://webmail.urbanlink.fr | head -1
dig +short webmail.urbanlink.fr @1.1.1.1
```

Attendu : `HTTP/2 200` (ou 302 vers `/SOGo`), et **`192.168.100.50`** en résolution
publique — l'IP privée, donc rien d'atteignable depuis Internet.

- [ ] **Étape 4 : Commit**

```bash
git add ansible/roles/edge_urbanlink/defaults/main.yml
git commit -m "feat(edge): publier webmail.urbanlink.fr en interne"
```

## Tâche 11 : Domaine, boîtes et clé DKIM

- [ ] **Étape 1 : Créer le compte administrateur**

Ouvrir `https://webmail.urbanlink.fr` depuis le LAN. Identifiants Mailcow par défaut :
`admin` / `moohoo`. **Changer le mot de passe immédiatement** et activer la double
authentification (TOTP) sur ce compte.

- [ ] **Étape 2 : Ajouter le domaine**

`Configuration → Mail Setup → Domains → Add domain` :
- Domaine : `urbanlink.fr`
- Quota par boîte : `10240` Mo
- Nombre de boîtes : `10`
- `Relay all recipients` : **décoché**

- [ ] **Étape 3 : Créer les boîtes et alias**

`Mailboxes → Add mailbox` — au minimum :

| Adresse | Rôle |
|---|---|
| `contact@urbanlink.fr` | boîte principale |
| `dmarc@urbanlink.fr` | réception des rapports agrégés DMARC |
| `tlsrpt@urbanlink.fr` | réception des rapports TLS-RPT |

Puis `Aliases` : `postmaster@urbanlink.fr` et `abuse@urbanlink.fr` → `contact@`.
**Ces deux adresses ne sont pas décoratives** : leur absence est un signal négatif pour
les grands fournisseurs, et `abuse@` est l'adresse que les opérateurs utilisent pour
signaler un problème avant de blacklister.

- [ ] **Étape 3b : Redémarrer SOGo après la création du domaine**

**Sans cela, le webmail répond `403 Unauthorized` à tous les utilisateurs**, alors que
tout le reste fonctionne — la console Mailcow accepte le mot de passe, l'IMAP aussi.
SOGo génère ses sources d'utilisateurs (une par domaine) **une seule fois, au démarrage
du conteneur**. La pile ayant été démarrée avant que le domaine n'existe, il a booté
sans aucune source.

```bash
ssh -J root@192.168.100.50 nbeny@10.0.0.140   'cd /opt/mailcow-dockerized && sudo docker compose restart sogo-mailcow'
```

Le rôle le fait désormais tout seul (handler `Redemarrer SOGo`, notifié par la création
de domaine). Vérifier :

```bash
ssh -J root@192.168.100.50 nbeny@10.0.0.140   "sudo docker compose -f /opt/mailcow-dockerized/docker-compose.yml exec -T sogo-mailcow sh -c 'grep -c urbanlink.fr /var/lib/sogo/GNUstep/Defaults/sogod.plist'"
```

Attendu : un nombre supérieur à 0. À `0`, le webmail refusera toute connexion.

⚠️ Piège de diagnostic rencontré : `c_password` vaut le même haché pour tous les
utilisateurs dans `_sogo_static_view`. **C'est normal et voulu** (« deny direct login »
dans le code de Mailcow) — SOGo n'authentifie pas par mot de passe, il fait confiance à
l'en-tête `x-webobjects-remote-user` posé par son nginx. Ne pas chercher là.

- [ ] **Étape 4 : Générer la clé DKIM**

`Configuration → Options → ARC/DKIM keys → Add ARC/DKIM key` :
- Domaine : `urbanlink.fr`
- Sélecteur : `dkim`
- Longueur : **2048 bits**

Copier l'enregistrement TXT proposé.

- [ ] **Étape 5 : Publier DKIM dans Cloudflare**

Zone `urbanlink.fr` : `dkim._domainkey` → `TXT` → la valeur copiée → DNS only.

- [ ] **Étape 6 : Vérifier**

```bash
dig +short TXT dkim._domainkey.urbanlink.fr @1.1.1.1 | head -c 120
```

Attendu : une valeur commençant par `v=DKIM1; k=rsa; p=MIIBIjANBg...`.

---

# PHASE 2 — Validation avant toute bascule

Aucun MX n'est modifié dans cette phase : Infomaniak continue de recevoir. On prouve
d'abord que l'**émission** est irréprochable.

## Tâche 12 : Autoriser le VPS en SPF, sans retirer Infomaniak

- [ ] **Étape 1 : Modifier le SPF dans Cloudflare**

Zone `urbanlink.fr`, enregistrement TXT racine, remplacer

```
v=spf1 include:spf.infomaniak.ch -all
```

par

```
v=spf1 ip4:147.79.102.17 include:spf.infomaniak.ch -all
```

Les deux origines sont légitimes pendant la transition. L'`include` ne tombera qu'à la
tâche 20.

- [ ] **Étape 2 : Vérifier**

```bash
dig +short TXT urbanlink.fr @1.1.1.1 | grep spf1
```

Attendu : la nouvelle valeur, **et une seule ligne SPF** — deux enregistrements SPF sur
un même nom invalident les deux, c'est une panne classique.

## Tâche 13 : Le test qui décide de tout

- [ ] **Étape 1 : Vérifier l'IP d'émission réelle**

Depuis la VM, à travers un conteneur du réseau Mailcow :

```bash
ssh -J root@192.168.100.50 nbeny@10.0.0.140 \
  'sudo docker run --rm --network mailcowdockerized_mailcow-network curlimages/curl:latest -s -4 https://ifconfig.me'
```

Attendu : **`147.79.102.17`**. Si c'est `82.65.87.60`, le routage du réseau Docker par
le tunnel ne fonctionne pas — reprendre la tâche 5, ne surtout pas envoyer de mail.

- [ ] **Étape 2 : Envoyer à mail-tester**

Obtenir une adresse jetable sur `https://www.mail-tester.com`, puis depuis le webmail
SOGo (`https://webmail.urbanlink.fr`), connecté en `contact@urbanlink.fr`, envoyer un
message avec un objet et un corps réels (quelques phrases — un message vide perd des
points).

- [ ] **Étape 3 : Lire le score**

Recharger la page mail-tester.

**Critère de passage : 10/10.** Les points manquants sont détaillés ligne par ligne.
Les causes attendues et leur correctif :

| Symptôme | Cause | Correctif |
|---|---|---|
| SPF `neutral`/`softfail` | l'IP vue n'est pas celle du VPS | reprendre l'étape 1 |
| DKIM absent | clé non publiée ou sélecteur différent | tâche 11 étapes 4-5 |
| `Reverse DNS does not match` | rDNS pas encore propagé | tâche 7, attendre |
| `You're listed in ...` | l'IP du VPS a été listée depuis | s'arrêter, investiguer |

- [ ] **Étape 4 : Test réel Gmail et Outlook**

Envoyer à une adresse `@gmail.com` **et** à une adresse `@outlook.com` (ou
`@hotmail.fr`).

Attendu : arrivée en **boîte de réception**, pas en spam. Dans Gmail, `Afficher
l'original` doit afficher :

```
SPF:   PASS with IP 147.79.102.17
DKIM:  PASS with domain urbanlink.fr
DMARC: PASS
```

- [ ] **Étape 5 : Consigner**

Noter le score et les trois verdicts. **C'est le point de non-retour du plan** : rien
ne bascule tant qu'ils ne sont pas tous verts.

---

# PHASE 3 — Bascule

## Tâche 14 : Abaisser les TTL

- [ ] **Étape 1 : TTL à 300 s**

Dans Cloudflare, passer le TTL des enregistrements `MX` et du `TXT` SPF de `Auto` à
**5 min**.

- [ ] **Étape 2 : Attendre l'ancien TTL**

Attendre **au moins une heure** avant la bascule, pour que les résolveurs aient purgé
l'ancienne valeur à long TTL. Sans cette attente, le retour arrière ne serait pas
réellement de cinq minutes.

## Tâche 15 : Basculer le MX

- [ ] **Étape 1 : Remplacer l'enregistrement MX**

Zone `urbanlink.fr` : supprimer `5 mta-gw.infomaniak.ch`, créer
`urbanlink.fr MX 10 mail.urbanlink.fr` (TTL 5 min).

- [ ] **Étape 2 : Vérifier la résolution**

```bash
dig +short MX urbanlink.fr @1.1.1.1
dig +short A mail.urbanlink.fr @1.1.1.1
```

Attendu : `10 mail.urbanlink.fr.` puis `147.79.102.17`.

- [ ] **Étape 3 : Test de réception de bout en bout**

Depuis une adresse Gmail, envoyer un message à `contact@urbanlink.fr`.

```bash
ssh -J root@192.168.100.50 nbeny@10.0.0.140 \
  'cd /opt/mailcow-dockerized && sudo docker compose logs --tail=50 postfix-mailcow | grep -i "from=<"'
```

Attendu : une ligne `connect from mail-...google.com[<IP Google>]` — **avec l'IP réelle
de Google**, pas `10.88.0.1`. C'est la seconde preuve que le DNAT préserve la source,
cette fois en conditions réelles.

- [ ] **Étape 4 : Vérifier le verdict de Rspamd**

Dans l'UI Mailcow, `Quarantine` puis `Rspamd UI → History` : le message doit afficher
`SPF: allow`, `DKIM: allow`, `DMARC: allow` pour l'expéditeur Gmail. Des verdicts
`na`/`neutral` signeraient une IP source perdue.

- [ ] **Étape 5 : Surveiller 48 h**

```bash
ssh -J root@192.168.100.50 nbeny@10.0.0.140 'sudo docker exec mailcowdockerized-postfix-mailcow-1 postqueue -p | tail -1'
```

Attendu : `Mail queue is empty`. Une file qui grossit signale un problème de sortie.

- [ ] **Étape 6 : Remonter les TTL**

Une semaine après la bascule, repasser MX et SPF en TTL `Auto`.

---

# PHASE 4 — Observabilité, sauvegardes, durcissement

## Tâche 16 : La sonde DNSBL

C'est la sonde qui répond directement à l'exigence de départ : savoir qu'on est listé
**avant** de le découvrir dans le courrier des autres.

**Fichiers :**
- Créer : `ansible/roles/mailcow/files/dnsbl-check.sh`
- Créer : `ansible/roles/mailcow/tasks/monitoring.yml`

- [ ] **Étape 1 : Le script**

`ansible/roles/mailcow/files/dnsbl-check.sh` :

```bash
#!/bin/bash
# Interroge les listes noires pour l'IP d'emission et ecrit le resultat au
# format textfile de node_exporter.
#
# ATTENTION -- Spamhaus REFUSE les requetes venant des resolveurs publics
# (1.1.1.1, 8.8.8.8) : elles repondent 127.255.255.254 "open resolver", ce qui
# ressemble a une inscription sans en etre une. On interroge donc le resolveur
# local, pas un resolveur public.
set -uo pipefail

IP=147.79.102.17
REV=$(echo "$IP" | awk -F. '{print $4"."$3"."$2"."$1}')
OUT=/var/lib/node_exporter/textfile/dnsbl.prom
TMP="${OUT}.$$"

ZONES="zen.spamhaus.org b.barracudacentral.org bl.spamcop.net psbl.surriel.com
dnsbl.sorbs.net dnsbl-1.uceprotect.net"

# La file d'attente est relevee ici aussi : deux metriques, un seul minuteur.
QUEUE=$(docker exec mailcowdockerized-postfix-mailcow-1 postqueue -p 2>/dev/null \
        | tail -1 | grep -oE '[0-9]+ Request' | grep -oE '^[0-9]+' || echo 0)
DEFERRED=$(docker exec mailcowdockerized-postfix-mailcow-1 \
           find /var/spool/postfix/deferred -type f 2>/dev/null | wc -l)

{
  echo "# HELP mail_dnsbl_listed 1 si l'IP d'emission est listee sur cette zone."
  echo "# TYPE mail_dnsbl_listed gauge"
  for z in $ZONES; do
    ans=$(dig +short +time=3 +tries=1 "${REV}.${z}" 2>/dev/null | head -1)
    case "$ans" in
      127.255.255.*) v=0 ;;   # reponse d'erreur du service, pas une inscription
      127.*)         v=1 ;;
      *)             v=0 ;;
    esac
    echo "mail_dnsbl_listed{zone=\"${z}\",ip=\"${IP}\"} ${v}"
  done
  echo "mail_dnsbl_last_check_timestamp_seconds $(date +%s)"
  echo "# HELP mail_queue_size Messages en attente dans la file Postfix."
  echo "# TYPE mail_queue_size gauge"
  echo "mail_queue_size ${QUEUE:-0}"
  echo "# HELP mail_queue_deferred Messages differes (echec temporaire de remise)."
  echo "# TYPE mail_queue_deferred gauge"
  echo "mail_queue_deferred ${DEFERRED:-0}"
} > "$TMP"

mv "$TMP" "$OUT"
```

- [ ] **Étape 2 : Le déploiement et le minuteur**

`ansible/roles/mailcow/tasks/monitoring.yml` :

```yaml
---
- name: Installer node_exporter et dnsutils
  ansible.builtin.apt:
    name: [prometheus-node-exporter, dnsutils]
    state: present
    update_cache: true
    cache_valid_time: 3600

- name: Creer le repertoire textfile
  ansible.builtin.file:
    path: /var/lib/node_exporter/textfile
    state: directory
    mode: "0755"

- name: Deposer la sonde DNSBL
  ansible.builtin.copy:
    src: dnsbl-check.sh
    dest: /usr/local/sbin/dnsbl-check.sh
    mode: "0750"

- name: Programmer la sonde toutes les 15 minutes
  ansible.builtin.cron:
    name: "sonde DNSBL de l'IP d'emission"
    minute: "*/15"
    job: "/usr/local/sbin/dnsbl-check.sh"

- name: Executer la sonde une premiere fois
  ansible.builtin.command:
    cmd: /usr/local/sbin/dnsbl-check.sh
  changed_when: true

- name: Autoriser node_exporter a lire les textfiles
  ansible.builtin.lineinfile:
    path: /etc/default/prometheus-node-exporter
    regexp: '^ARGS='
    line: 'ARGS="--collector.textfile.directory=/var/lib/node_exporter/textfile"'
  notify: Redemarrer node_exporter
```

Handler correspondant dans `ansible/roles/mailcow/handlers/main.yml` :

```yaml
---
- name: Redemarrer node_exporter
  ansible.builtin.systemd_service:
    name: prometheus-node-exporter
    state: restarted
```

- [ ] **Étape 3 : Vérifier**

```bash
ssh -J root@192.168.100.50 nbeny@10.0.0.140 'curl -s localhost:9100/metrics | grep mail_dnsbl'
```

Attendu : six lignes `mail_dnsbl_listed{...} 0` et un horodatage récent.

- [ ] **Étape 4 : Commit**

```bash
git add ansible/roles/mailcow
git commit -m "feat(mailcow): sonde DNSBL de l'IP d'emission en metrique Prometheus"
```

## Tâche 17 : Brancher la VM sur le Prometheus du cluster

**Fichiers :**
- Modifier : `ansible/roles/kubernetes/templates/kube-prometheus-stack-values.yaml.j2`

- [ ] **Étape 1 : Ajouter la cible statique**

Dans `additionalScrapeConfigs`, ajouter :

```yaml
    - job_name: mail-vm
      # La VM 140 est hors cluster : cible statique, pas de decouverte k8s.
      static_configs:
        - targets: ['10.0.0.140:9100']
          labels:
            instance: mail
```

- [ ] **Étape 2 : Appliquer**

```bash
ssh root@192.168.100.50 'cd /root/infra/ansible && ansible-playbook playbooks/20-debian-k8s.yml -l urbanlink -t observability'
```

- [ ] **Étape 3 : Vérifier la cible**

```bash
ssh root@192.168.100.50 \
  'curl -s -H "Host: prometheus.urbanlink.fr" http://10.0.0.111:30080/api/v1/targets | grep -o "mail-vm[^}]*health\":\"[a-z]*"'
```

Attendu : `health":"up`.

- [ ] **Étape 4 : Commit**

```bash
git add ansible/roles/kubernetes/templates/kube-prometheus-stack-values.yaml.j2
git commit -m "feat(observabilite): scraper la VM de messagerie"
```

## Tâche 18 : L'alerte qui compte

**Fichiers :**
- Modifier : `kube/urbanlink/observability/prometheus-alerts.yaml`

⚠️ Ce fichier est suivi par Argo CD (`selfHeal: true`) : un `kubectl apply` manuel sera
annulé en moins de trois minutes. Le changement **doit** passer par `master`.

- [ ] **Étape 1 : Écrire les règles**

```yaml
- alert: MailIPBlacklisted
  # Une seule inscription suffit : les grands fournisseurs consultent
  # plusieurs listes, et Spamhaus a lui seul ferme la porte de la moitie
  # d'Internet.
  expr: max(mail_dnsbl_listed) > 0
  for: 10m
  labels:
    severity: critical
  annotations:
    summary: "L'IP d'emission 147.79.102.17 est listee"
    description: >-
      Zone(s) concernee(s) visible(s) dans mail_dnsbl_listed.
      Le courrier sortant part en spam ou en rejet des maintenant.

- alert: MailDNSBLProbeStale
  # Une sonde muette est indiscernable d'une sonde rassurante : sans cette
  # regle, l'alerte precedente peut cesser de tirer sans qu'on le sache.
  expr: time() - mail_dnsbl_last_check_timestamp_seconds > 3600
  for: 15m
  labels:
    severity: warning
  annotations:
    summary: "La sonde DNSBL ne rend plus de resultat"

- alert: MailQueueGrowing
  # `mail_queue_size` et `mail_queue_deferred` sont produites par la meme sonde
  # que les listes noires (tache 16) : ne pas referencer d'unite systemd ici,
  # Postfix tourne dans un conteneur et n'en a pas.
  expr: mail_queue_size > 50 or mail_queue_deferred > 20
  for: 30m
  labels:
    severity: warning
  annotations:
    summary: "La file d'attente de la messagerie ne s'ecoule pas"
    description: >-
      File {{ $value }} messages. Cause probable : tunnel coupe, ou remises
      refusees par un grand fournisseur -- lire les logs postfix-mailcow.
```

- [ ] **Étape 2 : Appliquer et vérifier que la règle est chargée**

Suivre le chemin de déploiement habituel (`git push` sur `master` puis
`kubectl -n argocd annotate application urbanlink argocd.argoproj.io/refresh=hard
--overwrite`, puis **attendre** — voir la mémoire `argo-declencher-une-synchro`).

```bash
ssh root@192.168.100.50 \
  'curl -s -H "Host: prometheus.urbanlink.fr" http://10.0.0.111:30080/api/v1/rules | grep -c MailIPBlacklisted'
```

Attendu : `1` ou plus.

- [ ] **Étape 3 : Prouver que l'alerte peut tirer**

⚠️ Une alerte jamais vue tirer est une alerte dont on ne sait rien. Injecter
temporairement une valeur à 1 :

```bash
ssh -J root@192.168.100.50 nbeny@10.0.0.140 \
  'echo "mail_dnsbl_listed{zone=\"test\",ip=\"147.79.102.17\"} 1" | sudo tee /var/lib/node_exporter/textfile/fake.prom'
```

Attendre 10 minutes, vérifier l'alerte `firing` dans Alertmanager, **puis retirer le
fichier** :

```bash
ssh -J root@192.168.100.50 nbeny@10.0.0.140 'sudo rm /var/lib/node_exporter/textfile/fake.prom'
```

- [ ] **Étape 4 : Commit**

```bash
git add kube/urbanlink/observability/prometheus-alerts.yaml
git commit -m "feat(alertes): inscription en liste noire, sonde muette, file bloquee"
git push origin master
```

## Tâche 18b : Rapports DMARC lisibles et tableau de bord

Sans cette tâche, le passage en `p=reject` de la tâche 20 se ferait à l'aveugle : les
rapports DMARC arrivent en XML compressé, illisibles à l'œil.

**Fichiers :**
- Créer : `ansible/roles/mailcow/templates/parsedmarc.ini.j2`
- Créer : `kube/urbanlink/observability/dashboards/messagerie.json`

- [ ] **Étape 1 : Configurer parsedmarc**

`ansible/roles/mailcow/templates/parsedmarc.ini.j2` :

```jinja
# parsedmarc relève la boîte dmarc@ en IMAP, décode les rapports agrégés et
# les pousse dans l'Elasticsearch DÉJÀ présent dans le cluster. Aucune pile
# nouvelle : Kibana sait déjà les afficher.
[general]
save_aggregate = True
save_forensic = True

[imap]
host = 10.0.0.140
port = 993
ssl = True
user = dmarc@urbanlink.fr
password = {{ parsedmarc_imap_password }}

[mailbox]
watch = True
delete = False

[elasticsearch]
hosts = http://10.0.0.111:30092
ssl = False
```

Le mot de passe se passe en `-e parsedmarc_imap_password=...`, jamais dans le dépôt.

⚠️ Vérifier le port réel d'Elasticsearch dans le cluster avant de figer la valeur :

```bash
ssh root@192.168.100.50 'kubectl -n urbanconnect get svc | grep -i elastic'
```

- [ ] **Étape 2 : Lancer parsedmarc en conteneur sur la VM**

```yaml
- name: Lancer parsedmarc
  community.docker.docker_container:
    name: parsedmarc
    image: ghcr.io/domainaware/parsedmarc:latest
    restart_policy: unless-stopped
    volumes:
      - /etc/parsedmarc.ini:/etc/parsedmarc.ini:ro
    command: --config-file /etc/parsedmarc.ini
```

- [ ] **Étape 3 : Vérifier qu'un rapport est indexé**

Les rapports arrivent une fois par jour, décalés. Après 24 h :

```bash
ssh root@192.168.100.50 'curl -s http://10.0.0.111:30092/dmarc_aggregate*/_count'
```

Attendu : un `count` supérieur à 0.

- [ ] **Étape 4 : Le tableau de bord Grafana**

Créer `kube/urbanlink/observability/dashboards/messagerie.json` avec quatre panneaux
minimum, alimentés par les métriques réellement produites :

| Panneau | Requête |
|---|---|
| Inscriptions en liste noire | `max by (zone) (mail_dnsbl_listed)` |
| File d'attente | `mail_queue_size` et `mail_queue_deferred` |
| Fraîcheur de la sonde | `time() - mail_dnsbl_last_check_timestamp_seconds` |
| Ressources de la VM | `node_memory_MemAvailable_bytes{instance="mail"}`, `node_filesystem_avail_bytes{instance="mail",mountpoint="/"}` |

Suivre le format des tableaux de bord existants du même répertoire.

- [ ] **Étape 5 : Commit**

```bash
git add ansible/roles/mailcow kube/urbanlink/observability/dashboards/messagerie.json
git commit -m "feat(observabilite): rapports DMARC dans Kibana et tableau de bord messagerie"
git push origin master
```

## Tâche 19 : Sauvegardes

- [ ] **Étape 1 : Sauvegarde applicative quotidienne**

Sur la VM, via une tâche Ansible ajoutée à `roles/mailcow/tasks/main.yml` :

```yaml
- name: Programmer la sauvegarde Mailcow
  ansible.builtin.cron:
    name: "sauvegarde Mailcow"
    minute: "30"
    hour: "3"
    job: >-
      MAILCOW_BACKUP_LOCATION=/var/backups/mailcow
      {{ mailcow_dir }}/helper-scripts/backup_and_restore.sh backup all --delete-days 30
```

- [ ] **Étape 2 : Ajouter la VM à la rotation vzdump**

```bash
ssh root@192.168.100.50 'cat /etc/pve/jobs.cfg'
```

Ajouter la VM 140 au job existant, ou en créer un vers `pool2`.

- [ ] **Étape 3 : PROUVER la restauration**

Une sauvegarde non testée n'est pas une sauvegarde. Créer une boîte jetable
`test-restore@urbanlink.fr`, lancer une sauvegarde, supprimer la boîte, restaurer :

```bash
ssh -J root@192.168.100.50 nbeny@10.0.0.140 \
  'sudo MAILCOW_BACKUP_LOCATION=/var/backups/mailcow /opt/mailcow-dockerized/helper-scripts/backup_and_restore.sh restore'
```

Attendu : la boîte réapparaît dans l'UI. Supprimer ensuite la boîte de test.

- [ ] **Étape 4 : Commit**

```bash
git add ansible/roles/mailcow/tasks/main.yml
git commit -m "feat(mailcow): sauvegarde quotidienne et retention 30 jours"
```

## Tâche 20 : Durcir l'authentification

À faire **au moins deux semaines** après la bascule, une fois les rapports DMARC lus.

- [ ] **Étape 1 : Retirer Infomaniak du SPF**

Une fois le compte Infomaniak inutilisé, TXT racine :

```
v=spf1 ip4:147.79.102.17 -all
```

- [ ] **Étape 2 : Lire les rapports DMARC avant de durcir**

Ouvrir les rapports reçus sur `dmarc@urbanlink.fr`. Ne passer à l'étape suivante que
si **aucune source légitime** n'échoue. Un `p=reject` posé trop tôt fait disparaître
du courrier valide sans laisser de trace.

- [ ] **Étape 3 : Passer DMARC en quarantaine**

`_dmarc` TXT :

```
v=DMARC1; p=quarantine; pct=100; adkim=s; aspf=s; rua=mailto:dmarc@urbanlink.fr; ruf=mailto:dmarc@urbanlink.fr; fo=1
```

- [ ] **Étape 4 : Deux semaines plus tard, passer en rejet**

Remplacer `p=quarantine` par `p=reject`.

- [ ] **Étape 5 : MTA-STS et TLS-RPT**

Publier la politique via Traefik sur le VPS (nouveau conteneur nginx statique servant
`https://mta-sts.urbanlink.fr/.well-known/mta-sts.txt`) :

```
version: STSv1
mode: testing
mx: mail.urbanlink.fr
max_age: 604800
```

Puis les deux TXT :

```
_mta-sts   TXT  v=STSv1; id=20260904120000
_smtp._tls TXT  v=TLSRPTv1; rua=mailto:tlsrpt@urbanlink.fr
```

Passer `mode: enforce` après une semaine sans rapport d'échec.

- [ ] **Étape 6 : Vérifier**

```bash
curl -s https://mta-sts.urbanlink.fr/.well-known/mta-sts.txt
dig +short TXT _mta-sts.urbanlink.fr @1.1.1.1
dig +short TXT _dmarc.urbanlink.fr @1.1.1.1
```

---

# PHASE 5 — Transactionnel et sortie d'Infomaniak

## Tâche 21 : Le sous-domaine `notifs.urbanlink.fr`

- [ ] **Étape 1 : Ajouter le domaine dans Mailcow**

`Domains → Add domain` : `notifs.urbanlink.fr`, puis créer la boîte
`no-reply@notifs.urbanlink.fr` avec un mot de passe fort.

- [ ] **Étape 2 : Clé DKIM propre**

`ARC/DKIM keys → Add` : domaine `notifs.urbanlink.fr`, sélecteur `dkim`, 2048 bits.

Une clé distincte, c'est ce qui rend la réputation réellement séparée : une plainte sur
le transactionnel n'entraîne pas le courrier humain.

- [ ] **Étape 3 : Publier les trois enregistrements**

```
notifs                      TXT  v=spf1 ip4:147.79.102.17 -all
dkim._domainkey.notifs      TXT  <valeur fournie par Mailcow>
_dmarc.notifs               TXT  v=DMARC1; p=quarantine; rua=mailto:dmarc@urbanlink.fr
```

- [ ] **Étape 4 : Vérifier**

```bash
dig +short TXT notifs.urbanlink.fr @1.1.1.1
dig +short TXT dkim._domainkey.notifs.urbanlink.fr @1.1.1.1 | head -c 80
```

- [ ] **Étape 5 : Statuer sur le désabonnement un clic (RFC 8058)**

Les mails de Kratos — vérification d'adresse, récupération de mot de passe — sont
**transactionnels** : ils répondent à une action de l'utilisateur et sont hors du champ
de l'obligation de désabonnement, qui vise le courrier en masse. Rien à faire
aujourd'hui.

**À rouvrir le jour où UrbanConnect enverra la moindre newsletter ou notification
non sollicitée** : il faudra alors les en-têtes `List-Unsubscribe` et
`List-Unsubscribe-Post: List-Unsubscribe=One-Click`, sans quoi Gmail rejette en 550.
Consigner cette décision plutôt que la laisser implicite.

## Tâche 22 : Basculer Kratos

**Fichiers :**
- Modifier : `kube/urbanlink/secrets.env`

- [ ] **Étape 1 : Modifier les trois variables**

```
SMTP_CONNECTION_URI=smtps://no-reply%40notifs.urbanlink.fr:<motdepasse>@mail.urbanlink.fr:465/
SMTP_FROM_ADDRESS=no-reply@notifs.urbanlink.fr
SMTP_FROM_NAME=UrbanConnect
```

⚠️ `mail.urbanlink.fr:465` résout vers le VPS, qui ne publie **pas** le port 465. Le
cluster est sur le LAN : utiliser l'adresse de la VM, `10.0.0.140:465`, ou déclarer un
nom interne. Retenir : `smtps://no-reply%40notifs.urbanlink.fr:<motdepasse>@10.0.0.140:465/`.

- [ ] **Étape 2 : Déployer**

```bash
ssh root@192.168.100.50 'cd /root/infra/ansible && ansible-playbook playbooks/31-urbanlink-deploy.yml -t secrets'
ssh root@192.168.100.50 'kubectl -n urbanconnect rollout restart deployment/kratos'
```

- [ ] **Étape 3 : Vérifier avec un vrai parcours**

Déclencher une récupération de mot de passe depuis `https://urbanlink.fr` vers une
adresse Gmail contrôlée.

```bash
ssh root@192.168.100.50 'kubectl -n urbanconnect logs deployment/kratos --tail=50 | grep -i courier'
```

Attendu : `Sent out mailer` sans erreur, et le message **en boîte de réception**.

- [ ] **Étape 4 : Commit**

```bash
git add kube/urbanlink/secrets.env
git commit -m "feat(kratos): emettre via notifs.urbanlink.fr au lieu d'Infomaniak"
```

## Tâche 23 : Fermer la boucle

- [ ] **Étape 1 : Nettoyer le chantier abandonné du VPS**

```bash
ssh root@147.79.102.17 'ls /srv/mailcow-dockerized && docker volume ls | grep mailcow'
```

Après avoir confirmé qu'aucun conteneur mailcow ne tourne et que `vmail-vol-1` est
toujours vide (28 Ko) :

```bash
ssh root@147.79.102.17 'rm -rf /srv/mailcow-dockerized && docker volume ls -q | grep mailcowdockerized | xargs -r docker volume rm'
```

- [ ] **Étape 2 : ACTION UTILISATEUR — inscriptions de réputation**

- **Google Postmaster Tools** (`postmaster.google.com`) : ajouter `urbanlink.fr`,
  publier le TXT de vérification fourni.
- **Microsoft SNDS** (`sendersupport.olc.protection.outlook.com/snds/`) : demander
  l'accès aux données de `147.79.102.17`.
- **Microsoft JMRP** : inscrire l'IP pour recevoir les plaintes des utilisateurs
  Outlook — c'est le seul signal de réputation que Microsoft fournit.

- [ ] **Étape 3 : ACTION UTILISATEUR — résilier Infomaniak**

Seulement après **un mois** de fonctionnement sans incident, et après avoir récupéré ce
qui doit l'être : les boîtes ont démarré vides par décision, l'historique n'existe que
là-bas.

- [ ] **Étape 4 : Mettre le README à jour**

Ajouter la VM `mail` (140) au tableau des VMs et une section « Messagerie » renvoyant à
la spec.

```bash
git add README.md
git commit -m "docs: declarer la VM de messagerie dans le README"
```

---

## Vérification finale

- [ ] `dig MX urbanlink.fr` → `mail.urbanlink.fr` → `147.79.102.17`
- [ ] mail-tester à **10/10**
- [ ] Un message vers Gmail **et** vers Outlook arrive en boîte de réception
- [ ] `mail_dnsbl_listed` à 0 sur les six zones, sonde fraîche de moins d'une heure
- [ ] `webmail.urbanlink.fr` répond en LAN et résout en `192.168.100.50` publiquement
- [ ] `nbeny.fr` et `francois.nbeny.fr` répondent toujours en `200`
- [ ] Une restauration de boîte a été **réellement effectuée**, pas seulement configurée
- [ ] Aucun port autre que 25 n'est ouvert sur `147.79.102.17` pour la messagerie
