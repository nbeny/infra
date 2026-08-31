# VM macOS sur le nœud Proxmox

Runbook complet : ce que le matériel permet, ce que le dépôt automatise, et
l'unique étape manuelle qui reste.

---

## 1. Ce que ce nœud peut faire — et ne peut pas

Le nœud est un **2× Intel Xeon E5-2680** (Sandy Bridge-EP, 2012). Vérifié sur
la machine :

```console
# grep -o -m1 -E 'vmx|svm' /proc/cpuinfo
vmx
# grep -o avx2 /proc/cpuinfo
(aucune sortie)
```

VT-x est présent, la virtualisation imbriquée est active, QEMU 11.0.3 et OVMF
sont là. **Mais il n'y a pas AVX2.**

Depuis **macOS Ventura (13)**, le cache `dyld` d'Apple n'est compilé que pour
AVX2. QEMU ne sait pas émuler cette seule instruction en gardant tout le reste
en matériel — ce n'est pas un réglage à trouver, c'est un mur. Il faut du
Haswell (2013) au minimum.

| macOS | Sur ce nœud | Xcode maximum |
|---|---|---|
| Big Sur (11) | ✅ | 13.2.1 |
| **Monterey (12)** | ✅ **plafond** | **14.2** (SDK iOS 16.2) |
| Ventura (13) | ❌ AVX2 | — |
| Sonoma (14) et + | ❌ AVX2 | — |

### La conséquence pour de la CI Apple

Xcode 14.2 / SDK iOS 16.2 permet de **compiler, lancer `xcodebuild`, faire
tourner les tests unitaires et valider une branche**.

Il ne permet **pas de soumettre à l'App Store** : Apple exige un build produit
avec un SDK récent, et une soumission depuis cette VM sera rejetée. Si c'est
l'objectif, il faut soit changer de CPU, soit une vraie machine Apple, soit un
runner macOS hébergé.

Autres limites à connaître :

- **Pas d'accélération graphique.** L'interface est en rendu logiciel, donc
  lente. Sans importance pour `xcodebuild`, pénible pour les simulateurs iOS.
- **Monterey est en fin de vie** : plus de correctifs de sécurité.
- **Licence.** L'EULA d'Apple restreint macOS au matériel Apple. Courant en
  lab, mais autant le savoir.

### Le budget mémoire

macOS n'a **pas de virtio-balloon** : la VM prend son allocation et ne la rend
jamais. Sur ce nœud, déjà surengagé :

```
Total physique       110 Go
urbanlink (111)       96 Go   balloon: 0
macos-ci (140)         8 Go   pas de ballon possible
------------------------------
                     104 Go   -> il ne reste rien pour test-k8s ni kali-test
```

Avant de démarrer la VM macOS, arrêter `test-k8s` et `kali-test`, ou
redimensionner `urbanlink`.

Le disque, lui, ne pose pas de problème : **pool1 est vide avec 3,5 To**.

---

## 2. Récupérer l'OSK

macOS interroge le SMC d'Apple au démarrage et s'arrête si la puce ne répond
pas une chaîne précise de **64 caractères**. C'est l'OSK.

Elle n'est **pas versionnée** dans ce dépôt : elle s'extrait d'un vrai Mac.
Compiler et exécuter [`smc_read.c`](https://github.com/kholia/OSX-KVM/blob/master/smc_read.c)
sur une machine Apple :

```bash
gcc -o smc_read smc_read.c -framework IOKit
./smc_read
```

Elle sera passée en variable à chaque outil, jamais écrite dans un fichier
suivi par git.

---

## 3. Construire le template — automatisé

```bash
cd ansible
ansible-playbook playbooks/11-macos-template.yml -e pve_macos_osk='<64 caractères>'
```

Le rôle [`pve_macos`](../ansible/roles/pve_macos/README.md) :

1. **Refuse tout de suite** si l'OSK manque, ou si la version demandée exige
   AVX2 — plutôt que de laisser découvrir le problème trois heures plus tard
   devant une pomme figée.
2. **Prépare le nœud** — `ignore_msrs=Y` (immédiat + persistant), `dmg2img`.
   Sans `ignore_msrs`, l'invité panique avant même le logo Apple.
3. **Récupère les images** — OpenCore v21 et l'image de récupération Apple,
   convertie en image brute.
4. **Crée la VM 9200** — q35, OVMF sans clés pré-chargées, `ostype other`,
   VirtIO, ballooning désactivé, et la ligne `args:` portant le SMC émulé.

Idempotent : rejouer ne retélécharge rien et ne touche pas une VM existante.

---

## 4. Installer macOS — **manuel, une seule fois**

C'est l'étape qu'aucun outil ne rend non-attendue : le partitionnement passe
par Utilitaire de disque et l'installeur attend des clics. C'est exactement ce
que Packer fait pour Debian et Kali, mais qu'il ne peut pas faire ici.

Ouvrir **la console noVNC de la VM 9200** dans l'interface Proxmox, démarrer,
puis :

1. Dans le sélecteur OpenCore, choisir **macOS Base System**.
2. **Utilitaire de disque** → afficher tous les périphériques → sélectionner le
   disque VirtIO de 200 Go → **Effacer** → format **APFS**, schéma **Table de
   partition GUID**, nom `Macintosh HD`.
3. Quitter, **Installer macOS Monterey**, cibler `Macintosh HD`.
   La VM redémarre plusieurs fois : **toujours reprendre l'entrée `macOS
   Installer`** dans OpenCore jusqu'à la fin.
4. Assistant de configuration : créer le compte administrateur en le nommant
   **`nbeny`** (la valeur de `lab_admin_user`) — sinon l'inventaire Ansible ne
   tombera pas en face.

### Configurer l'invité pour Ansible

Toujours dans la console graphique, quatre choses, sans lesquelles rien de la
suite ne fonctionne :

**a. IP statique** — il n'y a **pas de DHCP sur `vmbr1`** et pas de cloud-init
sur macOS. Préférences Système → Réseau → Configurer IPv4 : Manuellement.

```
Adresse IP    10.0.0.140       (doit correspondre au champ `ip` de terraform.tfvars)
Sous-réseau   255.255.255.0
Routeur       10.0.0.1
DNS           1.1.1.1, 9.9.9.9
```

**b. SSH** — Préférences Système → Partage → cocher **Connexion à distance**.

**c. Clé publique** — dans le Terminal de la VM :

```bash
mkdir -p ~/.ssh && chmod 700 ~/.ssh
cat >> ~/.ssh/authorized_keys <<'EOF'
ssh-rsa AAAA...   # les clés de group_vars/all.yml
EOF
chmod 600 ~/.ssh/authorized_keys
```

**d. sudo sans mot de passe** — le rôle `macos_ci` s'exécute en `become` :

```bash
echo 'nbeny ALL=(ALL) NOPASSWD: ALL' | sudo tee /etc/sudoers.d/nbeny
sudo chmod 440 /etc/sudoers.d/nbeny
```

Vérifier depuis le poste client :

```bash
ssh -J root@192.168.100.50 nbeny@10.0.0.140 'sw_vers'
```

### Convertir en template

Une fois macOS installé, retirer l'installeur et figer la VM :

```bash
ssh root@192.168.100.50
qm stop 9200
qm set 9200 --delete ide0      # l'installeur BaseSystem ne sert plus
qm template 9200
```

> **OpenCore (`ide2`) doit rester attaché.** C'est le bootloader : sans lui la
> VM ne démarre plus du tout.

---

## 5. Déployer des VMs — automatisé

Dans `terraform/terraform.tfvars` (non versionné) :

```hcl
macos_osk = "................................................................"

macos_vms = {
  "macos-ci" = {
    vm_id     = 140
    ip        = "10.0.0.140"   # INFORMATIF : saisi à la main dans macOS
    cores     = 4              # puissance de 2 obligatoire
    memory    = 8192
    disk_size = 200
    datastore = "pool1"
    tags      = ["ci", "macos"]
  }
}
```

```bash
cd terraform && terraform apply
```

Le module [`vm-macos`](../terraform/modules/vm-macos/main.tf) est **distinct**
de `vm` : macOS n'a ni cloud-init, ni agent QEMU, ni template Packer. Les
fusionner aurait imposé de rendre conditionnels la moitié des blocs du module
générique, au risque de faire bouger les VMs Debian et Kali existantes.

Il pose `prevent_destroy = true` : l'installation de macOS coûte une session
manuelle et n'est pas refabricable automatiquement. Toute destruction devient
une erreur explicite au lieu d'une suppression silencieuse.

---

## 6. Configurer le runner — automatisé

Chaque VM clonée démarre sur l'écran de connexion, **sans sshd**. Ouvrir la
session une fois dans noVNC et réactiver Partage → Connexion à distance, puis :

```bash
cd ansible
ansible-playbook playbooks/22-macos-ci.yml

# avec enregistrement d'un runner GitHub Actions (jeton valable 1 h) :
ansible-playbook playbooks/22-macos-ci.yml \
  -e macos_ci_github_url=https://github.com/<org>/<repo> \
  -e macos_ci_github_runner_token=AXXXX...
```

Le rôle `macos_ci` installe les Command Line Tools (clang, git, `/usr/bin/python3`),
Homebrew, désactive la mise en veille, et enregistre le runner si un jeton est
fourni.

> **Xcode complet n'est pas automatisable.** Son téléchargement exige une
> authentification Apple. Il se pose à la main, une fois, depuis l'App Store
> ou un `.xip` — en s'arrêtant à **Xcode 14.2**, la dernière version que
> Monterey accepte.

---

## 7. La chaîne, de bout en bout

```
Ansible  playbooks/11-macos-template.yml     automatisé
             │                                (l'OSK est passée en variable)
             ▼
         VM 9200 amorçable mais vide
             │
   ┌─────────┴─────────┐
   │  INSTALLATION      │  MANUEL, une seule fois — noVNC
   │  GRAPHIQUE         │  + IP statique, sshd, clé, sudo NOPASSWD
   └─────────┬─────────┘
             ▼
         qm template 9200                     manuel (2 commandes)
             │
             ▼
Terraform  macos_vms → modules/vm-macos       automatisé
             │
             ▼
Ansible  playbooks/22-macos-ci.yml            automatisé
         CLT · Homebrew · runner GitHub
```

À comparer avec la chaîne Linux, entièrement automatisée :
`10-templates.yml` → Packer → Terraform → Ansible. La différence tient
entièrement au fait que macOS ne supporte ni cloud-init ni une installation
non-attendue.

---

## 8. Dépannage

| Symptôme | Cause |
|---|---|
| Kernel panic immédiat, avant le logo Apple | `ignore_msrs` non actif — `cat /sys/module/kvm/parameters/ignore_msrs` doit valoir `Y` |
| Panic au démarrage après un redimensionnement | Nombre de cœurs qui n'est pas une puissance de 2 |
| Pomme figée avec une barre qui n'avance plus | Version de macOS ≥ Ventura : AVX2 manquant, aucun contournement |
| OpenCore ne démarre pas, OVMF refuse | Clés Secure Boot pré-chargées — `pre-enrolled-keys=0` |
| L'installeur ne voit aucun disque | Images attachées en `media=cdrom` au lieu de disques |
| Pas d'interface réseau dans Préférences Système | Basculer `net_model` sur `vmxnet3` |
| Aucun paquet CLT proposé par `softwareupdate` | La VM n'a pas d'accès sortant — l'IP statique n'a pas été saisie |
| Ansible : « Don't run this as root! » | Une tâche Homebrew a perdu son `become: false` (`ansible.cfg` active `become` globalement) |
| Terraform attend puis échoue à lire l'IP | Un `agent.enabled = true` a été réintroduit : il n'existe pas d'agent QEMU pour macOS |
