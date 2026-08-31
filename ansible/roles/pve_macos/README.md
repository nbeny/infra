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
   `/etc/modprobe.d/kvm-macos.conf`), installe `dmg2img` et `python3-requests`.
2. **Récupère les images** — OpenCore (`thenickdude/KVM-Opencore`, version
   figée) et l'image de récupération Apple via `fetch-macOS-v2.py`, convertie
   en image brute par `dmg2img`.
3. **Crée la VM 9200** — q35, OVMF sans clés pré-chargées, `ostype other`,
   VirtIO réseau et disque, ballooning désactivé, et la ligne `args:` qui porte
   le SMC Apple émulé.

Tout est idempotent : rejouer le playbook ne retélécharge rien et ne touche
pas une VM déjà construite (sauf `-e pve_macos_force=true`, qui **détruit**
l'installation existante).

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
| `pve_macos_shortname` | `monterey` | `big-sur` possible ; `ventura`/`sonoma` refusés |
| `pve_macos_osk` | *(vide)* | **Obligatoire**, 64 caractères |
| `pve_macos_cores` | `4` | Doit être une puissance de 2, sinon kernel panic |
| `pve_macos_memory` | `8192` | Le nœud est déjà surengagé, voir le README racine |
| `pve_macos_disk_size` | `200` | Xcode ≈ 40 Go, chaque simulateur 8-12 Go |
| `pve_macos_net_model` | `virtio` | Replier sur `vmxnet3` si l'interface n'apparaît pas |

## Pièges rencontrés

- **`media=cdrom`** — les deux images sont attachées comme *disques*, pas comme
  lecteurs CD. macOS refuse de s'installer depuis un CD-ROM émulé.
- **`pre-enrolled-keys=0`** — avec les clés Microsoft pré-chargées, le Secure
  Boot d'OVMF refuse de lancer OpenCore, qui n'est signé par personne.
- **`ignore_msrs`** — sans ça, l'invité panique avant même le logo Apple, donc
  sans le moindre message exploitable.
- **Cœurs en puissance de 2** — 6 cœurs donnent un kernel panic au démarrage.
- **Pas de DHCP sur `vmbr1`** — l'IP statique se saisit à la main pendant
  l'installation. Il n'y a pas de cloud-init sur macOS pour le faire.
