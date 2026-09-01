# Rôle `pve_macos`

Construit la VM template macOS sur le nœud Proxmox : préparation de l'hôte,
récupération d'OpenCore et de l'image de récupération Apple, création de la VM
avec les arguments QEMU que macOS exige.

Le rôle **s'arrête avant l'installation** de macOS. Celle-ci est graphique
(partitionnement dans Utilitaire de disque, clics dans l'installeur) et aucun
outil ne la rend non-attendue. La suite est dans [`docs/macos-ci.md`](../../../docs/macos-ci.md).

## La contrainte qui décide de tout : pas d'AVX2

Le nœud est un **Xeon E5-2680** (Sandy Bridge, 2012). Il n'a pas AVX2.

Depuis **macOS Ventura (13)**, le cache `dyld` d'Apple n'est compilé que pour
AVX2, et QEMU ne sait pas émuler cette seule instruction tout en gardant le
reste en matériel. Ventura, Sonoma et au-delà sont donc **impossibles** ici —
ils s'installent parfois, mais ne démarrent jamais.

**Monterey (12) est le plafond.** Et Monterey plafonne lui-même à
**Xcode 14.2** (SDK iOS 16.2) : suffisant pour compiler et lancer des tests,
insuffisant pour une soumission App Store, qui exige aujourd'hui un SDK récent.

Le rôle refuse explicitement `ventura` et `sonoma` tant qu'AVX2 est absent.
Pour lever ce plafond, il faut changer de CPU (Haswell minimum).

## Ce que le rôle fait

1. **Prépare l'hôte** — `ignore_msrs=Y` (immédiat + persistant via
   `/etc/modprobe.d/kvm-macos.conf`), installe `dmg2img` et `python3-requests`,
   et pose un **DHCP** sur le bridge du lab (voir plus bas).
2. **Récupère les images** — OpenCore (`thenickdude/KVM-Opencore`, version
   figée) et l'image de récupération Apple via `fetch-macOS-v2.py`, convertie
   en image brute par `dmg2img`.
3. **Crée la VM 9200** — q35, OVMF sans clés pré-chargées, `ostype other`,
   disque VirtIO, réseau `vmxnet3`, ballooning désactivé, et la ligne `args:`
   qui porte le SMC Apple émulé.

Tout est idempotent : rejouer le playbook ne retélécharge rien et ne touche
pas une VM déjà construite (sauf `-e pve_macos_force=true`, qui **détruit**
l'installation existante).

## Le DHCP, et pourquoi il déborde du macOS

L'environnement de récupération de macOS **ne se configure qu'en DHCP**.
L'écran de réglage IP manuel n'existe qu'une fois le système installé, et il
n'y a pas de cloud-init sur macOS. Sans bail, l'installeur n'a aucune route :
il ne peut pas télécharger les ~12 Go de payload chez Apple.

Le rôle installe donc `dnsmasq` sur le nœud. **C'est le seul endroit où il
sort de son périmètre** : dnsmasq sert le bridge du lab en entier, pas
seulement la VM 9200. Deux garde-fous :

- **`port=0`** — DHCP seul. Sans ça dnsmasq ouvrirait aussi un résolveur DNS
  sur `10.0.0.1:53` que personne n'a demandé. Les invités reçoivent
  `1.1.1.1, 9.9.9.9` directement en option DHCP.
- **plage `10.0.0.200-250`** — hors des IPs statiques attribuées à la main
  (`.102`, `.111`, `.130`, `.140`).

`-e pve_macos_dhcp_enabled=false` sur un nœud qui a déjà un DHCP sur ce
bridge : deux serveurs sur le même segment se marchent dessus.

## L'OSK

macOS refuse de démarrer sans la réponse du SMC d'Apple : une chaîne de 64
caractères. Elle n'est **pas versionnée** dans ce dépôt et doit être fournie à
l'exécution :

```bash
ansible-playbook playbooks/11-macos-template.yml -e pve_macos_osk='<64 caractères>'
```

Elle s'extrait d'un vrai Mac — voir `docs/macos-ci.md`. Le rôle échoue tout de
suite si elle est absente ou n'a pas la bonne longueur, et la tâche qui la pose
est en `no_log` pour qu'elle ne finisse pas dans les journaux Ansible.

## Variables principales

| Variable | Défaut | Rôle |
|---|---|---|
| `pve_macos_vmid` | `9200` | Hors des plages 9000-9101 déjà prises |
| `pve_macos_storage` | `pool1` | pool1 est vide et a 3,5 To ; pool2 est à 47 % |
| `pve_macos_version` | `monterey` | `big-sur` possible ; `ventura`/`sonoma` refusés (AVX2) |
| `pve_macos_osk` | *(vide)* | **Obligatoire**, 64 caractères |
| `pve_macos_cores` | `4` | Doit être une puissance de 2, sinon kernel panic |
| `pve_macos_memory` | `8192` | Le nœud est déjà surengagé, voir le README racine |
| `pve_macos_disk_size` | `200` | Xcode ≈ 40 Go, chaque simulateur 8-12 Go |
| `pve_macos_net_model` | `vmxnet3` | Le pilote VirtIO réseau n'est pas toujours chargé en mode Recovery |
| `pve_macos_dhcp_enabled` | `true` | Pose `dnsmasq` sur le bridge du lab — sans lui l'installeur n'a pas de réseau |
| `pve_macos_boot_args` | *(vide)* | `-v debug=0x100 keepsyms=1` pour diagnostiquer une panique |

## Pièges rencontrés

- **`--shortname` de `fetch-macOS-v2.py` ment.** Sa table code en dur
  `os_type: latest` pour `monterey` : elle demande le plus récent système que
  supporte la carte. Mesuré le 2026-08-31, `--shortname monterey` a renvoyé
  **Sequoia** (Darwin 24.4), qui exige AVX2 — logo Apple, panique, retour au
  sélecteur, sans un mot d'explication. Le rôle passe un `--board-id` explicite
  avec `--os-type default`, puis **relit la version Darwin dans l'image** et
  refuse de continuer si elle ne correspond pas.
- **`Misc.Boot.Timeout = 0`** dans l'OpenCore amont signifie « attendre
  indéfiniment ». Un runner resterait bloqué au sélecteur après chaque
  redémarrage. Corrigé sur le fichier avant l'import.
- **La commande passée à `script -qec` doit tenir sur une seule ligne.** Dans
  un scalaire YAML plié (`>-`), les lignes plus indentées que la première
  gardent leurs retours à la ligne : `script` n'exécutait que `python3
  fetch-macOS-v2.py`, sans arguments, et le script retombait sur son menu
  interactif avant de mourir sur `EOFError`.
- **`script -qec` n'est pas décoratif non plus.** La vérification du chunklist
  appelle `os.get_terminal_size()` : sans terminal elle lève
  `[Errno 25] Inappropriate ioctl for device` *après* avoir téléchargé 840 Mio.
  Un `failed_when: false` accepterait en silence une image tronquée.

- **`media=cdrom`** — les deux images sont attachées comme *disques*, pas comme
  lecteurs CD. macOS refuse de s'installer depuis un CD-ROM émulé.
- **`pre-enrolled-keys=0`** — avec les clés Microsoft pré-chargées, le Secure
  Boot d'OVMF refuse de lancer OpenCore, qui n'est signé par personne.
- **`ignore_msrs`** — sans ça, l'invité panique avant même le logo Apple, donc
  sans le moindre message exploitable.
- **Cœurs en puissance de 2** — 6 cœurs donnent un kernel panic au démarrage.
- **Le disque de 200 Go n'apparaît pas comme cible d'installation.** C'est le
  piège qui coûte le plus de temps, parce qu'il ne ressemble pas à une erreur :
  l'installeur affiche sa sélection de disque avec le seul `macOS Base System`
  grisé, et rien n'indique pourquoi. Un disque **brut** n'est pas proposé — il
  faut d'abord le partitionner. Mesuré le 2026-09-01 : `diskutil list physical`
  montrait `/dev/disk0  214.7 GB` sans schéma de partition. Voir
  [`docs/macos-ci.md`](../../../docs/macos-ci.md) § 4.
- **Le DHCP n'est pas un confort.** Le mode Recovery n'a pas d'écran de
  réglage IP manuel : sans bail, l'installeur ne télécharge rien.
- **Le mode Recovery s'endort au bout de 10 minutes** (`pmset -g` :
  `sleep 10`). Un téléchargement de deux heures sans personne devant la
  console meurt en silence — retour au menu Recovery, aucune erreur.
  `pmset -a sleep 0 displaysleep 0 disksleep 0` avant de lancer l'installation.
