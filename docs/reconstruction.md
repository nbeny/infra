# Reconstruire le lab depuis ce dépôt

Ordre complet pour redéployer toute l'architecture, du nœud nu jusqu'aux
applications. Établi le 2026-10-09 en confrontant le dépôt à la prod : chaque
étape dit ce qui est automatisé, ce qui reste manuel, et ce qui manquerait.

> **Ce que le dépôt reconstruit :** l'infrastructure (nœud, VMs, cluster,
> messagerie, CI, réseau). **Ce qu'il ne reconstruit pas :** les données
> (comptes, annonces, courrier, base du jeu) — elles reviennent des
> sauvegardes, étape 8.

## 0. Ce qu'il faut avoir sous la main AVANT

Rien de ceci n'est dans git. Les perdre, c'est ne pas pouvoir reconstruire.

| Secret | Où il vit en prod | Sert à |
|---|---|---|
| `kube/urbanlink/secrets.env` | poste (copie de référence), nœud, VM 111 | Secret `urbanconnect-secrets`, comptes des consoles |
| `/root/argocd_infra.key` (nœud) = `ssh/argocd_infra.key` (poste) | les deux | clé de déploiement GitHub d'Argo CD |
| `/root/.secrets/cloudflare.ini` | nœud | DNS-01 certbot + écritures DNS des rôles (token de **compte** `cfat_…`, cf. note) |
| `/root/.secrets/wireguard/`, `crowdsec-mail-agent.pw` | nœud | tunnel VPS ↔ mail, agent CrowdSec de la messagerie |
| `terraform/terraform.tfvars` | nœud | token API Proxmox (recréable : étape 1) |
| `mikrotik/secrets.env` | poste | accès API du routeur |
| PAT GitHub (Administration: write) | à créer | enregistrer les runners (étape 5) |
| Données Turtle WoW (`turtle.7z`, DBC 1.18) | **seulement dans la VM 150** et son vzdump | serveur de jeu (étape 7) |

⚠️ `secrets.env` a **trois copies qui divergent** (relevé du 2026-10-09) : la
plus complète est celle du poste (66 clés). Avant de rejouer `31`, pousser
celle-là sur le nœud. Il y manque encore `GRAFANA_PG_PASSWORD`, exigé par
`20 --tags k8s-observability` : le générer avec `scripts/secrets/bootstrap.sh`.

## 1. Nœud Proxmox

Réinstaller Proxmox depuis l'ISO, rétablir l'accès SSH root par clé, puis :

```bash
tar -czf - --exclude=.git . | ssh root@192.168.100.50 'mkdir -p /root/infra && tar -xzf - -C /root/infra'
cd /root/infra/ansible
ansible-galaxy collection install -r requirements.yml
ansible-playbook playbooks/00-proxmox-host.yml
ansible-playbook playbooks/00-proxmox-host.yml -t token -e pve_create_api_token=true   # -> terraform.tfvars
ansible-playbook playbooks/32-tls-certificates.yml    # après avoir reposé cloudflare.ini
ansible-playbook playbooks/95-hardening.yml           # bascules de group_vars/proxmox.yml
ansible-playbook playbooks/33-urbanlink-edge.yml
```

**Manuel / non couvert par le dépôt** (relevé du 2026-10-09) :
- **OpenResty** 1.27.1.2 est compilé à la main dans `/usr/local/openresty`, avec
  son unité systemd et un `nginx.conf` maison. Les rôles edge supposent qu'il
  existe. Idem pour `conf.d/10-crowdsec_nginx.conf` (bouncer openresty),
  `20-default-deny.conf` et `30-cloudflare-realip.conf`.
- **Chaîne CrowdSec → MikroTik** : `exabgp` + `cs-exabgp-bouncer` et
  `crowdsec-blocklist-mirror`. Seul `mikrotik/config/60-crowdsec-bgp.rsc` en
  parle.
- Réseau : `pve_manage_network: false`. Le template `interfaces.j2` n'a pas la
  ligne `pointopoint 192.168.100.1` présente en prod — à vérifier avant de
  passer `-e pve_manage_network=true`.
- Stockage : recréer `pool1` (raidz1, 3 disques). `pool2` (un seul disque) est
  corrompu et désactivé depuis le 2026-10-04 — ne plus rien y mettre.

## 2. Templates

```bash
ansible-playbook playbooks/10-templates.yml          # 9000, 9001
cd ../packer && packer init . && packer build .      # 9100, 9101 (~1 h)
```

⚠️ **En prod aujourd'hui, 9001, 9100 et 9101 ont leurs disques sur pool2** :
ils sont inutilisables. Une reconstruction d'urbanlink (profil `debian-k8s`)
**exige** de reconstruire 9100 d'abord. Seul 9000 est sur pool1.

## 3. VMs

```bash
cd /root/infra/terraform
terraform init && terraform plan && terraform apply
```

Les VMs sont décrites dans **`lab.auto.tfvars`** (versionné) ; `terraform.tfvars`
ne contient que le token. Les VMs `debian-base` (mail, ci-runner, wow-turtle)
se créent avec `agent = false`, puis on repasse à `true` après le premier
playbook (procédure dans le bloc `mail` de `lab.auto.tfvars`).

Pour une VM **neuve**, retirer de `ci-runner` les surcharges cloud-init
(`admin_user`, `ssh_public_keys`, `cloud_init_interface`) et mettre à jour
son `ansible_user` dans `inventory/group_vars/ci_nodes.yml`.

## 4. Cluster UrbanLink (VM 111)

Ordre réel — il n'est pas linéaire :

```bash
cd /root/infra/ansible
ansible-playbook playbooks/20-debian-k8s.yml -l urbanlink --skip-tags k8s-observability
ansible-playbook playbooks/31-urbanlink-deploy.yml     # Secret, namespace, passerelle
ansible-playbook playbooks/20-debian-k8s.yml -l urbanlink --tags k8s-observability
ansible-playbook playbooks/32-argocd.yml               # Argo suit master -> applique kube/urbanlink
ansible-playbook playbooks/34-console-accounts.yml
```

- `20` monte etcd sur le disque SSD (`k8s_etcd_disk`, host_vars) **avant**
  `kubeadm init`.
- `20 --tags k8s-observability` a besoin de `/opt/urbanlink-kube/secrets.env`,
  déposé par `31` : d'où l'aller-retour.
- **Restaurer les données (étape 8) AVANT de laisser Argo démarrer les
  applications**, sinon le backend migre une base vide.
- Les images viennent du registre `10.0.0.130:5000` (VM ci-runner). Si
  ci-runner a été perdue avec son registre : la CI d'UrbanConnct ne part que
  sur un push vers `main` — rejouer le dernier run réussi
  (`gh run rerun <id> --repo nbeny/UrbanConnct`) republie les images, puis
  vérifier que le tag écrit dans `kube/urbanlink/kustomization.yaml` existe
  bien dans le registre.

## 5. CI (VM 130)

```bash
ansible-playbook playbooks/35-ci-registry.yml -e github_runners_pat=github_pat_...
```

Docker, registre du lab, swap, les cinq runners (3 UrbanConnct, folionbeny,
FrouFolio). Côté urbanlink, containerd fait déjà confiance au registre
(`docker_insecure_registries`, host_vars).

Amorçage SSH sur une VM montée à la main : voir l'en-tête de `35-ci-registry.yml`.

## 6. Messagerie (VM 140 + VPS)

```bash
ansible-playbook playbooks/40-mail-vm.yml
ansible-playbook playbooks/41-mail-tunnel.yml
ansible-playbook playbooks/42-mailcow.yml        # commit Mailcow figé : mailcow_commit
ansible-playbook playbooks/43-mail-antiabus.yml
bash scripts/mail/verifier-messagerie.sh
```

Les quatre passent en `--check --diff` contre la prod (vérifié le 2026-10-09).
`42` crée le MX et `mail.urbanlink.fr` s'ils manquent.

**Hors dépôt, sur le VPS** : Traefik et les sites nbeny.fr / francois.nbeny.fr,
CrowdSec du VPS et son bouncer, le verrou `cf_lock` (443 réservé à
Cloudflare), le runner `folionbeny-vps`. **PTR** de 147.79.102.17 : panneau
Hostinger (vaut `srv859050.hstgr.cloud`, devrait être `mail.urbanlink.fr`).

## 7. Turtle WoW (VM 150)

La reconstruction vit dans le dépôt **`nbeny/wow-turtle-serveur`** (sources,
confs, unités systemd, dump `tw_world`), le site dans **`nbeny/wow-urbanlink`**
(`deploy/install-vm.sh`). Ici : la VM (`lab.auto.tfvars`, groupe
`game_nodes`), le DNS `turtle.urbanlink.fr` (`33 -t dns`), le DNAT MikroTik.

Les données serveur (DBC/maps du repack, DBC talents 1.18) n'existent que dans
la VM : **restaurer le vzdump de 150** est de loin le plus court.

## 8. Données

| Quoi | Sauvegarde | Restauration |
|---|---|---|
| Postgres, MinIO, etcd d'UrbanLink | nuit 03:30 → `/pool1/backups/urbanlink/` | à écrire : `scripts/urbanlink/tester-restauration.sh` ne restaure que dans un Postgres jetable |
| VM 111 entière | vzdump dimanche 02:00 | `qmrestore` |
| VMs 130, 140, 150 | vzdump quotidien 04:30 | `qmrestore` |

Tout est sur pool1, **dans le même serveur** : aucune copie hors site.

## 9. Réseau hors nœud

- **MikroTik** : `mikrotik/restore.sh` rejoue `mikrotik/config/*.rsc`.
- **Freebox (manuel)** : rediriger 22, 80, 443, 3724, 8091 vers `192.168.1.50`.
- **DNS Cloudflare** : rejoué par les rôles (`33 -t dns`, `42`). Non géré :
  les CAA, et les restes Infomaniak (`autoconfig`, `autodiscover`,
  `20260105._domainkey`) à supprimer.
- L'IP publique de la maison (`82.65.87.60`) n'est pas garantie fixe : si elle
  change, mettre à jour `edge_urbanlink_public_ip` et rejouer `33 -t dns`.
