# Lab Proxmox — Terraform, Packer, Ansible

Provisionnement reproductible du lab Proxmox `pve` (192.168.100.50) : des VMs
**Debian avec Docker et Kubernetes**, des VMs **Kali outillées**, un accès SSH
unifié par rebond, et de quoi reconstruire aussi bien le nœud Proxmox que le
host principal.

---

> **Déjà en place sur le nœud.** La chaîne complète a été déployée et validée
> de bout en bout. Token API créé, `/root/infra` synchronisé, Terraform 1.16 et
> Packer 1.16 installés, les quatre templates construits (**9000**, **9001**,
> **9100**, **9101**) et deux VMs de démonstration déployées :
>
> | VM | VMID | IP | État vérifié |
> |---|---|---|---|
> | `urbanlink` | 111 | 10.0.0.111 | 16 vCPU / 64 Go / 700 Go — k8s 1.36.4, `local-path`, Istio ambient (Traefik et CrowdSec retirés du cluster — CrowdSec vit sur l'openresty du nœud), **stack UrbanLink déployé** (62 objets, 16 pods `Running`) |
> | `test-k8s` | 190 | 10.0.0.190 | Kubernetes 1.36.4 `Ready`, 8 pods `Running`, Docker 29.7, Helm 4.2, k9s |
> | `kali-test` | 120 | 10.0.0.120 | 2899 paquets, `kali-linux-large` (nmap, metasploit, burpsuite, bloodhound, impacket…) |
>
> Les deux sont taguées `test`, en `on_boot = false`, et se suppriment en
> retirant leur entrée de `terraform.tfvars`. Les playbooks ont été rejoués
> deux fois : `changed=0` au second passage sur les deux profils.
>
> Les fichiers de secrets (`terraform.tfvars`, `lab.auto.pkrvars.hcl`) sont
> renseignés côté nœud uniquement — ils ne sont pas dans git.
> Tu peux donc reprendre directement à [Ajouter une VM](#ajouter-une-vm).
>
> **Pas encore fait, volontairement :** `UrbanConnect` (VM 100) et `Kali`
> (VM 103) n'ont pas été adoptées — c'est ta production, la décision te revient.
> Voir [Reprendre en main une VM existante](#reprendre-en-main-une-vm-existante).

## Sommaire

- [Comment ça marche](#comment-ça-marche)
- [Ce qui existe déjà sur le nœud](#ce-qui-existe-déjà-sur-le-nœud)
- [Prérequis](#prérequis)
- [Démarrage rapide](#démarrage-rapide)
- [Accès SSH](#accès-ssh)
- [Ajouter une VM](#ajouter-une-vm)
- [Ajouter une VM macOS](#ajouter-une-vm-macos)
- [Mettre à jour le lab](#mettre-à-jour-le-lab)
- [Reprendre en main une VM existante](#reprendre-en-main-une-vm-existante)
- [Sauvegardes et restauration](#sauvegardes-et-restauration)
- [Reconstruire le host principal](#reconstruire-le-host-principal)
- [Reconstruire le nœud Proxmox](#reconstruire-le-nœud-proxmox)
- [Référence](#référence)
- [Dépannage](#dépannage)

---

## Comment ça marche

Trois outils, trois responsabilités qui ne se chevauchent pas :

```
  Images cloud officielles          Debian 13 genericcloud · Kali genericcloud
            │
            │  ANSIBLE  (rôle pve_templates)
            ▼
  ┌─────────────────────┐
  │  Socles cloud-init  │           9000 tpl-debian-13-base
  │  (base templates)   │           9001 tpl-kali-base
  └─────────────────────┘
            │
            │  PACKER  (clone + provisionne + reconvertit en template)
            ▼
  ┌─────────────────────┐           9100 tpl-debian-k8s   docker · containerd · kubeadm
  │  Templates golden   │           9101 tpl-kali-tools   kali-linux-large
  └─────────────────────┘
            │
            │  TERRAFORM  (clone complet + cloud-init : IP, hostname, clés)
            ▼
  ┌─────────────────────┐
  │      Les VMs        │           10.0.0.x sur vmbr1
  └─────────────────────┘
            │
            │  ANSIBLE  (jour 2 : cluster k8s, mises à jour, dérive)
            ▼
        Lab utilisable
```

**Pourquoi ce découpage.** Le logiciel lourd (Docker, Kubernetes, les 15 Go
d'outils Kali) est installé **une seule fois** dans le template. Créer une VM
ensuite prend une minute au lieu d'une heure, et deux VMs du même profil sont
bit-à-bit identiques. Terraform ne fait que du matériel et de l'identité ;
Ansible reste la seule source de vérité pour la configuration.

**Les rôles Ansible sont partagés** entre le build Packer et la configuration
de jour 2 : `roles/docker` est le même code dans les deux cas. Pas de dérive
possible entre « ce qui est dans l'image » et « ce qu'on applique ensuite ».

### Où tourne quoi

Le **nœud Proxmox est le nœud de contrôle**. Terraform, Packer et Ansible
s'exécutent dessus, depuis `/root/infra`.

Ce n'est pas un choix par défaut : les VMs vivent sur `vmbr1` (10.0.0.0/24), un
réseau interne NATé qui n'est routable que depuis le nœud. Packer doit joindre
la VM en cours de build en SSH, et Ansible doit joindre chaque VM — seul le
nœud peut le faire sans tunnel.

Depuis Windows tu édites le repo, tu le pousses sur le nœud, tu lances les
commandes. Ton poste garde un accès SSH direct à toutes les VMs via le rebond.

---

## Ce qui existe déjà sur le nœud

Relevé au moment de la mise en place — utile pour comprendre les choix faits.

| | |
|---|---|
| Proxmox VE | 9.1.7 (Debian trixie, noyau 6.17) |
| Nœud | `pve` — 32 vCPU, 118 Go de RAM |
| `vmbr0` | 192.168.100.50/24, passerelle 192.168.100.1 — administration |
| `vmbr1` | 10.0.0.1/24, NAT vers vmbr0 — réseau des VMs, **pas de DHCP** |
| Stockage | `pool1` ZFS (861 Go libres) · `pool2` ZFS (2,5 To libres) · `local` (ISO) |

VMs préexistantes, **non gérées par Terraform** :

| VMID | Nom | IP | État | Note |
|---|---|---|---|---|
| 100 | UrbanConnect | 10.0.0.100 | démarrée | Host principal — Debian + Docker, 96 Go / 24 vCPU / 1 To |
| 101 | Alesio | — | arrêtée | |
| 102 | Other | 10.0.0.102 | démarrée | Accessible depuis le LAN sur `192.168.100.50:4242` (DNAT) |
| 103 | Kali | 10.0.0.103 | arrêtée | |

> **Terraform ne touche jamais à ces VMs.** Elles ne sont pas dans son état.
> Ansible peut les configurer une fois « adoptées » (voir plus bas), ce qui est
> purement additif.

Le nouveau matériel va sur **`pool2`** : `pool1` est rempli à 76 %.

---

## Prérequis

**Sur le nœud Proxmox** — tout est installé par le playbook `00-proxmox-host.yml` :
Ansible (déjà présent, core 2.19.4), Terraform 1.16, Packer 1.16.

**Sur ton poste Windows** — rien d'autre que `git` et `ssh`, tous deux déjà là.
Pas besoin d'installer Terraform, Packer ni Ansible localement.

---

## Démarrage rapide

### 1. Pousser le repo sur le nœud

Depuis `C:\Users\nbeny\Documents\GitHub\infra`, dans Git Bash :

```bash
ssh root@192.168.100.50 'rm -rf /root/infra/kube /root/infra/mikrotik /root/infra/scripts /root/infra/docs'
tar -czf - --exclude=.git --exclude=mikrotik/secrets.env .   | ssh root@192.168.100.50 'mkdir -p /root/infra && tar -xzf - -C /root/infra'
```

À refaire après chaque modification du repo.

> **Le `rm -rf` n'est pas décoratif.** `tar` ajoute et écrase, il n'efface
> **jamais**. Un fichier supprimé du dépôt survit indéfiniment sur le nœud, et
> `31-urbanlink-deploy.yml` le resynchronise ensuite sur la VM. C'est
> exactement ce qui s'est produit en supprimant les manifests Traefik : ils
> sont revenus sur la VM après avoir disparu du dépôt.
>
> Les quatre répertoires listés sont **entièrement gérés par git**. `ansible/`
> et `terraform/` en sont volontairement absents : ils contiennent des
> fichiers qui n'existent que sur le nœud — `inventory/20-terraform.yml`,
> généré par Terraform, et les deux fichiers de secrets. Les effacer casserait
> l'inventaire et obligerait à recréer le token API.

Alternative plus propre, maintenant que le dépôt a un remote : `git pull` sur
le nœud, qui gère les suppressions nativement. Il faut lui donner un accès en
lecture au dépôt privé (clé de déploiement).

### 2. Configurer le nœud

```bash
ssh root@192.168.100.50
cd /root/infra/ansible

ansible-playbook playbooks/00-proxmox-host.yml
```

Dépôts APT (no-subscription actif, enterprise désactivé), outils de base,
Terraform et Packer, routage IPv4 persistant, paire de clés SSH pour root.

### 3. Créer le token API pour Terraform

```bash
ansible-playbook playbooks/00-proxmox-host.yml -t token -e pve_create_api_token=true
```

Le secret n'est affiché **qu'une fois**. Reporte-le dans les deux fichiers :

```bash
cp /root/infra/terraform/terraform.tfvars.example /root/infra/terraform/terraform.tfvars
cp /root/infra/packer/lab.auto.pkrvars.hcl.example /root/infra/packer/lab.auto.pkrvars.hcl
# puis renseigner pve_api_token et proxmox_api_token_secret
```

Ces deux fichiers sont ignorés par git.

### 4. Construire les socles cloud-init

```bash
ansible-playbook playbooks/10-templates.yml
```

Télécharge les images officielles Debian 13 et Kali, en fait les templates
**9000** et **9001**. Compte quelques minutes.

### 5. Construire les templates golden

```bash
cd /root/infra/packer
packer init .

packer build -only='debian-k8s.*' .    # ~15 min
packer build -only='kali.*' .          # ~45 min avec kali-linux-large
```

Produit **9100** (`tpl-debian-k8s`) et **9101** (`tpl-kali-tools`).

Pour reconstruire par-dessus un template existant, ajoute `-force`.

### 6. Déployer les VMs

```bash
cd /root/infra/terraform
terraform init
terraform plan       # relis toujours le plan
terraform apply
```

Les machines sont décrites dans `terraform.tfvars`.

### 7. Configurer les VMs

```bash
cd /root/infra/ansible
ansible guests -m ping

ansible-playbook playbooks/20-debian-k8s.yml   # cluster Kubernetes
ansible-playbook playbooks/21-kali.yml         # finitions Kali
```

Terraform a écrit `inventory/20-terraform.yml` : les nouvelles VMs sont déjà
dans l'inventaire, rien à déclarer à la main.

---

## Accès SSH

Les VMs ne sont pas routables depuis le LAN. Tout passe par le nœud, en
**ProxyJump** — pas de règle NAT à maintenir, ça marche pour toute nouvelle VM
sans rien reconfigurer.

Copie `ssh/config.example` dans `%USERPROFILE%\.ssh\config` (ou ajoute-le à ta
config existante). Ensuite, depuis Windows :

```bash
ssh test-k8s          # alias déclaré
ssh 10.0.0.190        # n'importe quelle VM du lab, par IP
```

`terraform output ssh_config` régénère ce bloc avec les VMs réellement déployées.

**Tunnels utiles :**

```bash
ssh -L 8006:127.0.0.1:8006 pve      # interface web Proxmox → https://localhost:8006
ssh -L 3389:127.0.0.1:3389 kali     # bureau Kali en RDP  → mstsc /v:localhost:3389
```

Les clés publiques autorisées sont listées dans
`ansible/inventory/group_vars/all.yml` (`lab_ssh_public_keys`). C'est le seul
endroit à modifier : Terraform lit ce même fichier, donc une clé ajoutée là
part à la fois dans cloud-init et dans Ansible.

---

## Ajouter une VM

Une entrée dans `terraform/terraform.tfvars` :

```hcl
vms = {
  "k8s-lab" = {
    profile   = "debian-k8s"      # ou "kali"
    vm_id     = 111
    ip        = "10.0.0.111"
    cores     = 4
    memory    = 8192
    disk_size = 64
  }
}
```

Puis :

```bash
cd /root/infra/terraform && terraform apply
cd ../ansible && ansible-playbook playbooks/20-debian-k8s.yml -l k8s-lab
```

**Convention :** le dernier octet de l'IP est égal au VMID. Terraform vérifie
l'unicité des VMID et des IP, la validité des adresses, et refuse la plage
9000-9999 réservée aux templates.

Pour supprimer une VM : retire son entrée et `terraform apply`.

---

## Ajouter une VM macOS

Chaîne **différente** des VMs Linux, et volontairement séparée : macOS n'a ni
cloud-init, ni agent QEMU, ni template Packer. Runbook complet dans
[`docs/macos-ci.md`](docs/macos-ci.md).

### Le plafond matériel, à connaître avant de commencer

Le nœud est un **Xeon E5-2680** (Sandy Bridge, 2012) : il n'a **pas AVX2**.
Depuis **macOS Ventura (13)**, le cache `dyld` d'Apple n'est compilé que pour
AVX2, et QEMU ne peut pas émuler cette seule instruction. Ventura et au-delà
ne démarreront jamais ici — il faudrait du Haswell (2013) minimum.

**Monterey (12) est le maximum**, ce qui plafonne **Xcode à 14.2** (SDK iOS
16.2) : de quoi compiler et lancer des tests, mais **pas de quoi soumettre à
l'App Store**, qui exige un SDK récent.

macOS n'a pas non plus de ballooning : la VM prend ses 8 Go et ne les rend
jamais. Sur un nœud déjà surengagé, ça se planifie (voir le commentaire de
budget dans `terraform.tfvars.example`).

### Les quatre étapes

```bash
# 1. Construire le template (automatisé)
cd ansible
ansible-playbook playbooks/11-macos-template.yml -e pve_macos_osk='<64 caractères>'

# 2. Installer macOS -- MANUEL, une seule fois, via la console noVNC
#    puis, sur le nœud :  qm stop 9200 && qm set 9200 --delete ide0 && qm template 9200

# 3. Déployer (automatisé) -- après avoir rempli macos_vms dans terraform.tfvars
cd ../terraform && terraform apply

# 4. Configurer le runner (automatisé)
cd ../ansible && ansible-playbook playbooks/22-macos-ci.yml
```

Seule l'étape 2 est manuelle, et elle est irréductible : le partitionnement
passe par Utilitaire de disque et l'installeur attend des clics. C'est ce que
Packer fait pour Debian et Kali, et qu'il ne peut pas faire ici.

**L'OSK** est la chaîne de 64 caractères que renvoie le SMC des Macs Apple ;
macOS ne démarre pas sans elle. Elle n'est pas versionnée : elle se passe en
variable à Ansible et se pose dans `terraform.tfvars`.

**L'IP est saisie à la main** dans macOS pendant l'installation : il n'y a pas
de DHCP sur `vmbr1` et pas de cloud-init. Le champ `ip` de `macos_vms` est
purement informatif — il ne sert qu'à générer l'inventaire Ansible, et rien ne
vérifie qu'il correspond à l'invité.

---

## Mettre à jour le lab

```bash
cd /root/infra/ansible

# Nœud Proxmox + toutes les VMs (une VM à la fois)
ansible-playbook playbooks/90-update.yml

# En autorisant les redémarrages
ansible-playbook playbooks/90-update.yml -e common_reboot_if_required=true

# Les VMs seulement
ansible-playbook playbooks/90-update.yml -l guests
```

Le nœud n'est **jamais** redémarré automatiquement : il héberge des VMs en
production. Le playbook signale qu'un redémarrage est en attente et te laisse
choisir le moment.

`kubelet`, `kubeadm` et `kubectl` sont volontairement gelés (`apt-mark hold`) —
une mise à jour hors séquence kubeadm casse un cluster. Leur montée de version
a son propre playbook :

```bash
ansible-playbook playbooks/91-k8s-upgrade.yml -e kubernetes_version=1.37
```

kubeadm interdit de sauter une mineure : 1.36 → 1.38 se fait en deux passes.

**Rafraîchir les templates** (nouvelles images amont, nouvelle version de k8s) :

```bash
ansible-playbook playbooks/10-templates.yml -e pve_templates_force=true
cd ../packer && packer build -force .
```

Les VMs déjà déployées ne bougent pas : Terraform fait des clones **complets**,
sans lien vers le template.

---

## Reprendre en main une VM existante

`UrbanConnect` et `Kali` ont été créées à la main : pas de compte `nbeny`, pas
de clés SSH. Le playbook d'adoption les rend pilotables par Ansible **via
l'agent invité QEMU**, sans avoir besoin d'un accès SSH préalable :

```bash
ansible-playbook playbooks/05-adopt-existing.yml
```

Il crée le compte, injecte les clés publiques, accorde `sudo` sans mot de passe
et s'assure que `python3` est présent. **Strictement additif** — rien n'est
supprimé ni écrasé.

La VM doit être démarrée et l'agent QEMU actif. Pour d'autres VMs :

```bash
ansible-playbook playbooks/05-adopt-existing.yml -e '{"adopt_vms":[{"vmid":101,"name":"Alesio"}]}'
```

Ensuite `ansible guests -m ping` doit répondre, et `20-debian-k8s.yml`
s'applique à UrbanConnect comme à n'importe quelle VM neuve.

---

## Sauvegardes et restauration

Deux couches, parce qu'elles répondent à deux questions différentes.

| | Quoi | Quand | Où | Poids |
|---|---|---|---|---|
| **Données** | Postgres (5 bases + rôles), MinIO, instantané etcd | chaque nuit 03:30 | `/pool1/backups/urbanlink/` | ~30 Mo |
| **Image VM** | `vzdump` de la VM 111 entière | dimanche 02:00 | `pool1-backup` | ~100 Go |

La couche « données » sert 99 fois sur 100 : elle se restaure **base par base**,
en quelques secondes, et répond à « une table a été effacée » ou « il me faut
l'état d'avant-hier ». L'image VM répond à « la VM n'existe plus » — elle est
inutilisable pour récupérer une seule table.

```bash
# Sauvegarder tout de suite, sans attendre la nuit
systemctl start urbanlink-sauvegarde.service
journalctl -u urbanlink-sauvegarde.service -n 20 -o cat

# PROUVER que ça se restaure (~3 min, ne touche pas la production)
bash scripts/urbanlink/tester-restauration.sh
```

L'exercice de restauration monte un Postgres jetable, y rejoue les rôles puis
chaque base, et **compare le nombre de lignes au manifeste** pris le jour de la
sauvegarde. C'est le seul contrôle qui distingue « des fichiers existent » de
« on peut repartir » : une restauration qui rend une base vide réussit du point
de vue de `pg_restore`.

### Ce qui n'est PAS sauvegardé, et pourquoi

Elasticsearch (`npm run search:reindex` le reconstruit depuis Postgres),
Nominatim (95 Go ré-importables depuis Geofabrik) et Redis (cache, OTP,
présence). Les sauvegarder coûterait cher pour des données qu'une commande
régénère.

### ⚠️ Deux limites à connaître

**`pool2-backup` n'était pas une sauvegarde.** C'est un répertoire
`/pool2/backups` : il vit sur le **même disque** — un seul Hitachi — que les
disques de VM qu'il protège. Les deux jobs `vzdump` pointent désormais sur
`pool1-backup` (raidz1, trois disques). Les archives déjà prises sur
`pool2-backup` n'ont pas été déplacées.

**pool1 est dans le même serveur.** Ça protège d'une panne de disque et d'une
fausse manœuvre, **pas** d'un incendie ni d'un vol. La copie hors-site reste à
faire.

### Le piège qui a motivé tout ceci

`roles/pve_hardening` ne sauvegardait que la VM 140, au motif — écrit dans ses
`defaults` — que « le cluster se redéploie depuis ce dépôt ». C'était vrai
quand ça a été écrit. Ça ne l'est plus : le dépôt reconstruit
l'**infrastructure**, pas les **données**. Comptes, annonces, commandes,
identités Kratos, photos déposées : rien de tout cela n'est dans git.

## Reconstruire le host principal

UrbanConnect (VM 100) est décrite dans `terraform.tfvars.example`, commentée.
Deux approches selon le besoin :

**Le maintenir en place** — sans rien détruire :

```bash
ansible-playbook playbooks/05-adopt-existing.yml     # une seule fois
ansible-playbook playbooks/20-debian-k8s.yml -l urbanconnect
```

Installe Kubernetes à côté du Docker existant et prend la main sur la
configuration. La VM continue de tourner.

**Le reconstruire à neuf** — décommente le bloc `urbanconnect` du tfvars. Il
reprend le dimensionnement exact (12 cœurs × 2 sockets, 96 Go, 1 To) mais sous
un **nouveau VMID (110)** et une nouvelle IP (10.0.0.110).

C'est délibéré : Terraform ne réutilise pas le VMID 100, donc la machine
actuelle n'est jamais en danger. Tu déploies la neuve, tu migres tes données,
tu retires l'ancienne quand tu es sûr de toi. Un `terraform destroy` mal placé
ne peut pas emporter ta production.

---

## Reconstruire le nœud Proxmox

Après une réinstallation de Proxmox depuis l'ISO :

1. Rétablir l'accès SSH par clé pour `root`
2. Pousser le repo (`tar | ssh`, étape 1 du démarrage rapide)
3. `ansible-playbook playbooks/00-proxmox-host.yml`
4. Recréer le token API (étape 3)
5. Reconstruire templates et VMs (étapes 4 à 7)

**Le réseau n'est pas géré par défaut.** `pve_manage_network: false` dans
`group_vars/proxmox.yml` : le rôle sait écrire `/etc/network/interfaces` à
partir de `roles/pve_host/templates/interfaces.j2`, mais une erreur là coupe
l'accès au nœud. Sur une réinstallation, relis le template, vérifie le nom de
l'interface physique (`pve_uplink_interface`, `nic3` ici) puis :

```bash
ansible-playbook playbooks/00-proxmox-host.yml -t network -e pve_manage_network=true
```

Le fichier existant est sauvegardé et horodaté avant écriture.

---

## Référence

### Arborescence

```
infra/
├── ansible/
│   ├── inventory/
│   │   ├── 00-static.yml            nœud PVE + VMs créées à la main
│   │   ├── 20-terraform.yml         généré par Terraform (non versionné)
│   │   └── group_vars/              ← la config du lab vit ici
│   ├── playbooks/
│   │   ├── 00-proxmox-host.yml      le nœud
│   │   ├── 05-adopt-existing.yml    adopter une VM créée à la main
│   │   ├── 10-templates.yml         socles cloud-init 9000/9001
│   │   ├── 11-macos-template.yml    template macOS 9200 (install manuelle)
│   │   ├── 20-debian-k8s.yml        VMs Debian → cluster k8s + storage + edge
│   │   ├── 21-kali.yml              VMs Kali → outils
│   │   ├── 22-macos-ci.yml          VMs macOS → Xcode CLT + runner
│   │   ├── 30-urbanlink-images.yml  build des images applicatives
│   │   ├── 31-urbanlink-deploy.yml  déploiement du stack UrbanLink
│   │   ├── 90-update.yml            mises à jour système
│   │   ├── 91-k8s-upgrade.yml       montée de version Kubernetes
│   │   ├── 95-hardening.yml         correctifs de l'audit sécurité
│   │   └── packer-*.yml             appelés par Packer uniquement
│   └── roles/                       pve_host · pve_templates · pve_hardening
│                                    common · docker · kubernetes
│                                    kali_tools · image_cleanup
│                                    pve_macos · macos_ci
├── kube/
│   ├── README.md                    provenance, déploiement, résultats
│   └── urbanlink/                   manifests du stack UrbanConnect
├── docs/
│   ├── audit-securite.md            audit DevOps & sécurité du nœud
│   └── macos-ci.md                  runbook macOS — plafond AVX2, install manuelle
├── packer/                          builds des templates golden
├── terraform/                       description des VMs
└── ssh/config.example               ProxyJump pour ton poste
```

### Charges applicatives

Le cluster Kubernetes n'est pas vide : [`kube/`](kube/) contient le stack
**UrbanLink** (27 composants) et la marche à suivre pour le déployer. Le rôle
`kubernetes` fournit ce qu'un cluster kubeadm nu n'a pas et que ces manifests
exigent : une StorageClass par défaut (`local-path`) et un ingress.

**L'ingress est Istio** (mode ambient), qui a remplacé Traefik. Il apporte en
plus le mTLS automatique entre pods et les `AuthorizationPolicy` — soit la
réponse au constat K2 de l'audit. Le mode ambient n'est pas un choix de
confort : ce stack a trois Jobs et un pod `hostNetwork`, que des sidecars
casseraient. Détail de la correspondance Traefik → Istio, et des deux
régressions assumées (CrowdSec, ACME), dans [`kube/README.md`](kube/README.md).

**Le déploiement est piloté par Argo CD**, qui suit `master` de ce dépôt et
réconcilie `kube/urbanlink/`. La CI du dépôt applicatif n'exécute aucun
`kubectl` sur les charges de travail : elle construit les images, les pousse
dans le registre du lab (`ansible/roles/registry`, sur la VM `ci-runner`), et
écrit **ici** le tag et la configuration. Un `git push` sur `main` d'UrbanConnct
suffit donc à mettre le cluster à jour. Partage des rôles détaillé dans
[`kube/README.md`](kube/README.md).

### Sécurité

[`docs/audit-securite.md`](docs/audit-securite.md) est l'audit du nœud, réalisé
sur la machine et non déduit. Les correctifs sont codés dans le rôle
`pve_hardening`, **tous désactivés par défaut** :

```bash
ansible-playbook playbooks/95-hardening.yml --check --diff   # voir sans rien changer
```

### Plan d'adressage

| Plage | Usage |
|---|---|
| 10.0.0.1 | Passerelle (le nœud Proxmox) |
| 10.0.0.100-103 | VMs préexistantes |
| 10.0.0.110-189 | VMs Terraform (dont 10.0.0.140 macOS, **saisie à la main**) |
| 10.0.0.190 | VM de test |
| 10.0.0.240-241 | IP temporaires des builds Packer |

| VMID | Usage |
|---|---|
| 100-103 | VMs préexistantes |
| 110-899 | VMs Terraform |
| 9000-9001 | Socles cloud-init |
| 9100-9101 | Templates golden |
| 9200 | Template macOS (installé à la main) |

### Fichiers de configuration

| Fichier | Contenu |
|---|---|
| `ansible/inventory/group_vars/all.yml` | Réseau, stockage, compte admin, **clés SSH** — lu aussi par Terraform |
| `ansible/inventory/group_vars/proxmox.yml` | Options du nœud : mises à jour, réseau, token |
| `ansible/inventory/group_vars/debian_nodes.yml` | Version de Kubernetes, CNI, options Docker |
| `ansible/inventory/group_vars/kali_nodes.yml` | Métapaquet Kali, interface graphique |
| `ansible/inventory/group_vars/macos_nodes.yml` | VMs macOS — hors du groupe `guests` (ni apt, ni cloud-init) |
| `terraform/terraform.tfvars` | Token API, liste des VMs et **OSK macOS** — **non versionné** |
| `packer/lab.auto.pkrvars.hcl` | Secret du token API — **non versionné** |

### Choix par défaut

| | |
|---|---|
| Kubernetes | 1.36 (dernier patch : 1.36.4). 1.37 disponible — une variable à changer |
| CNI | Flannel, pod CIDR 10.244.0.0/16. Cilium disponible (`k8s_cni: cilium`) |
| Cluster | Mono-nœud, taint du control-plane retiré pour que les pods s'y planifient |
| Métapaquet Kali | `kali-linux-large` (~15 Go) — couvre l'essentiel des outils |
| Interface Kali | Pas de GUI. `kali_install_gui=true` ajoute XFCE + xrdp sur 127.0.0.1 |
| cgroups | containerd en driver `systemd` — obligatoire pour kubelet |

**« Tous les outils Kali »** au sens strict, c'est `kali-linux-everything` :
plus de 100 Go et plusieurs heures de build. `kali-linux-large` est le choix
par défaut parce qu'il couvre en pratique tout ce qui sert. Pour le paquet
complet :

```bash
packer build -only='kali.*' -force -var kali_metapackage=kali-linux-everything .
```

Pense à monter `disk_size` du socle Kali (`roles/pve_templates/defaults/main.yml`,
64 Go par défaut) à 200 avant, sinon le build sature le disque.

---

## Dépannage

**`ansible guests -m ping` échoue sur une VM neuve**
cloud-init n'a pas fini. Attends une minute, ou regarde la console série :
`qm terminal <vmid>`.

**`ansible guests -m ping` échoue sur `urbanconnect` ou `kali`**
Normal tant qu'elles ne sont pas adoptées : elles n'ont ni compte `nbeny` ni
clés SSH. Voir [Reprendre en main une VM existante](#reprendre-en-main-une-vm-existante).

**apt échoue avec « Temporary failure resolving »**
La VM a du réseau mais pas de résolution DNS. Sur les images où
`systemd-resolved` est actif (Kali), cloud-init écrit les serveurs DNS dans
`/etc/network/interfaces.d/` alors que `/etc/resolv.conf` pointe sur le stub
`127.0.0.53`, qui n'a alors aucun résolveur amont :

```bash
resolvectl status | head -20     # "DNS Servers:" doit être renseigné
```

Le rôle `common` traite ce cas en premier (avant tout apt) via un fichier
`/etc/systemd/resolved.conf.d/99-lab.conf`, et échoue avec un message explicite
si la résolution ne fonctionne toujours pas. Relancer le playbook suffit.

**Packer reste bloqué sur « Waiting for SSH »**
La VM de build n'a pas d'IP. Vérifie que `ipconfig` et `ssh_host` pointent bien
sur la même adresse, et que rien d'autre n'occupe 10.0.0.240 / 10.0.0.241.

**Terraform : `VM 9100 not found`**
Les templates golden n'ont pas encore été construits — reprends à l'étape 5.

**Terraform veut recréer une VM sans raison**
Vérifie que tu n'as pas modifié le template entre-temps. Le `disk_size` ne peut
qu'augmenter : le réduire force un remplacement.

**`kubectl get nodes` reste en `NotReady`**
Le CNI n'est pas encore prêt. `kubectl -n kube-flannel get pods`. Si les pods
tournent mais que le nœud reste NotReady, regarde containerd — deux pièges,
tous deux traités par le rôle `docker` mais qui reviennent si on réinstalle
containerd à la main :

```bash
grep SystemdCgroup /etc/containerd/config.toml     # doit être `true`
grep disabled_plugins /etc/containerd/config.toml  # ne doit PAS contenir "cri"
```

Le paquet `containerd.io` de Docker livre un `config.toml` minimal avec
`disabled_plugins = ["cri"]` : dans cet état kubelet ne peut pas parler à
containerd du tout. Le rôle détecte ce fichier et le remplace par la sortie de
`containerd config default`, qui active CRI.

**Le nœud dit « No valid subscription »**
Cosmétique, sans effet. `pve_remove_subscription_nag: true` dans
`group_vars/proxmox.yml` retire le popup.

**`pool2` n'est pas en thin provisioning**
Un disque de 100 Go y réserve 100 Go. Pour du thin :
`pvesm set pool2 --sparse 1` — ne s'applique qu'aux volumes créés ensuite.
