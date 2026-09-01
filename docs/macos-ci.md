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
2. **Prépare le nœud** — `ignore_msrs=Y` (immédiat + persistant), `dmg2img`,
   et un **DHCP** (`dnsmasq`, plage `10.0.0.200-250`, DHCP seul sans DNS) sur
   le bridge du lab. Sans `ignore_msrs`, l'invité panique avant même le logo
   Apple ; sans DHCP, l'installeur n'a aucun réseau (voir § 4).
3. **Récupère les images** — OpenCore v21 (dont il corrige le `Timeout`, voir
   plus bas) et l'image de récupération Apple, convertie en image brute.
4. **Vérifie ce qu'Apple a réellement envoyé** — voir ci-dessous, ce n'est pas
   du zèle.
5. **Crée la VM 9200** — q35, OVMF sans clés pré-chargées, `ostype other`,
   VirtIO, ballooning désactivé, et la ligne `args:` portant le SMC émulé.

Idempotent : rejouer ne retélécharge rien et ne touche pas une VM existante.

### Pourquoi le rôle n'utilise pas `--shortname`

`fetch-macOS-v2.py` propose un raccourci `--shortname monterey`. **Il ne faut
pas s'en servir.** Sa table interne code en dur `os_type: latest` pour cette
entrée : elle demande à Apple *le plus récent système que supporte cette
carte*, pas Monterey. Écrite quand Monterey était le plus récent, elle a pourri
en silence.

Mesuré ici le 2026-08-31 : `--shortname monterey` a renvoyé **Sequoia**
(Darwin 24.4), qui exige AVX2. Résultat : la VM affichait le logo Apple,
paniquait, et revenait au sélecteur OpenCore — sans qu'aucun message n'annonce
la substitution.

Le rôle passe donc un `--board-id` explicite avec `--os-type default`, puis
**lit la version Darwin dans l'image téléchargée** et refuse de continuer si
elle ne correspond pas :

```
Darwin 21.6 -- conforme a monterey. Xcode ira au maximum jusqu'a 14.2.
```

La chaîne `Darwin Kernel Version XX.Y` est lisible en clair dans l'image brute.
Les noms marketing (« macOS Monterey », « macOS Sequoia »…) y sont *tous*
présents à cause des tables de localisation : ils ne servent à rien.

| Darwin | macOS | Démarre ici |
|---|---|---|
| 20.x | Big Sur | ✅ |
| 21.x | Monterey | ✅ |
| 22.x | Ventura | ❌ AVX2 |
| 23.x | Sonoma | ❌ AVX2 |
| 24.x | Sequoia | ❌ AVX2 |

### Le `Timeout` d'OpenCore

L'image OpenCore amont sort avec `Misc.Boot.Timeout = 0`, ce qui signifie
« attendre indéfiniment » dans le sélecteur. Acceptable pour une machine de
bureau, inutilisable pour un runner : après le moindre redémarrage la VM reste
bloquée et ne revient jamais seule. Le rôle le passe à 5 secondes, sur le
fichier, avant l'import dans Proxmox.

---

## 4. Installer macOS — **manuel, une seule fois**

C'est l'étape qu'aucun outil ne rend non-attendue : le partitionnement passe
par Utilitaire de disque et l'installeur attend des clics. C'est exactement ce
que Packer fait pour Debian et Kali, mais qu'il ne peut pas faire ici.

Ouvrir **la console noVNC de la VM 9200** dans l'interface Proxmox, démarrer,
puis :

1. Dans le sélecteur OpenCore, choisir **macOS Base System**.
2. **Partitionner le disque — l'étape à ne pas sauter.** Un disque brut n'est
   pas proposé comme cible : si on lance l'installeur d'abord, sa sélection de
   disque n'affiche que `macOS Base System` grisé, sans le moindre message
   expliquant que les 200 Go existent mais sont vides. C'est le piège le plus
   coûteux de ce runbook.

   Au choix, **Utilitaire de disque** → afficher tous les périphériques →
   disque VirtIO de 200 Go → **Effacer** → **APFS**, **Table de partition
   GUID**, nom `Macintosh HD`.

   Ou, plus sûr et vérifiable, **Utilitaires → Terminal** :

   ```bash
   diskutil list physical      # reperer le disque de 214.7 GB (= 200 Gio)
   diskutil eraseDisk APFS "Macintosh HD" GPT /dev/disk0
   ```

   La sortie doit finir par `Finished erase on disk0`. Vérifier au passage que
   le réseau est là — sans lui l'installeur ne téléchargera rien :

   ```bash
   ipconfig getifaddr en0      # une IP dans 10.0.0.200-250, servie par dnsmasq
   ping -c 2 17.253.144.10     # un serveur Apple
   ```

3. **Désactiver la veille — sans ça l'installation ne finit pas.** Toujours
   dans le Terminal de Recovery :

   ```bash
   pmset -a sleep 0 displaysleep 0 disksleep 0
   pmset -g | grep -E 'sleep'   # doit afficher trois 0
   ```

   Le mode Recovery sort avec **`sleep 10`**. Le téléchargement dure deux
   heures et personne ne touche la souris : la VM s'endort, l'installeur est
   tué, et on retrouve le menu Recovery **sans le moindre message d'erreur** —
   `/var/log/install.log` ne montre qu'un `Assertion TimedOut.
   Type:InternalPreventSleep` suivi de `Display is turned off`. Mesuré le
   2026-09-01 : perdu après 12 Go déjà téléchargés.

   `pmset` se réinitialise à chaque démarrage du mode Recovery : le refaire
   après chaque redémarrage tant que l'installation n'est pas finie.

4. Quitter, **Réinstaller macOS Monterey**, cibler `Macintosh HD`.
   Le téléchargement fait ~12 Go et annonce 2 à 3 h.
   La VM redémarre plusieurs fois : **toujours reprendre l'entrée `macOS
   Installer`** dans OpenCore jusqu'à la fin.
5. Assistant de configuration : créer le compte administrateur en le nommant
   **`nbeny`** (la valeur de `lab_admin_user`) — sinon l'inventaire Ansible ne
   tombera pas en face.

### Configurer l'invité pour Ansible

Toujours dans la console graphique, quatre choses, sans lesquelles rien de la
suite ne fonctionne :

**a. IP statique** — le `dnsmasq` du nœud sert un bail à l'installeur, mais
c'est une béquille pour la phase d'installation : elle vient de la plage
`10.0.0.200-250` et changera. Terraform et l'inventaire Ansible attendent une
adresse fixe, et macOS n'a pas de cloud-init pour la poser.
Préférences Système → Réseau → Configurer IPv4 : Manuellement.

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
| **Logo Apple puis retour au sélecteur OpenCore** | **L'image téléchargée n'est pas celle demandée (piège `--shortname`). Vérifier : `grep -a -o -m1 -E 'Darwin Kernel Version [0-9]+\.[0-9]+' BaseSystem.img`** |
| Pomme figée avec une barre qui n'avance plus | Version de macOS ≥ Ventura : AVX2 manquant, aucun contournement |
| La VM reste sur le sélecteur OpenCore indéfiniment | `Misc.Boot.Timeout = 0` dans `config.plist` |
| Diagnostiquer une panique | Ajouter `-v` à `NVRAM > Add > 7C43…9F82 > boot-args` dans `config.plist` : le texte de la panique s'affiche à l'écran |
| OpenCore ne démarre pas, OVMF refuse | Clés Secure Boot pré-chargées — `pre-enrolled-keys=0` |
| L'installeur ne voit aucun disque | Images attachées en `media=cdrom` au lieu de disques |
| Pas d'interface réseau dans Préférences Système | `net_model` doit valoir `vmxnet3` : le pilote VirtIO réseau n'est pas toujours chargé en mode Recovery |
| **L'installeur ne propose que `macOS Base System`, grisé** | **Le disque de 200 Go est brut. Un disque non partitionné n'est pas une cible : l'effacer en APFS/GUID d'abord (§ 4)** |
| L'installeur ne télécharge rien, reste sur « Loading installation information » | Pas de bail DHCP. `ipconfig getifaddr en0` dans le Terminal de Recovery ; côté nœud, `journalctl -u dnsmasq` doit montrer un `DHCPACK` |
| **Retour au menu Recovery en pleine installation, sans erreur** | **Veille du mode Recovery (`sleep 10`). `pmset -a sleep 0 displaysleep 0 disksleep 0` avant de relancer (§ 4). Signature dans `/var/log/install.log` : `Assertion TimedOut. Type:InternalPreventSleep`** |
| Le nœud ne répond pas au DHCP alors que dnsmasq tourne | La requête arrive **sur** le nœud, pas en transit : c'est la politique d'entrée d'ufw qui la jette, pas la politique de forward |
| Aucun paquet CLT proposé par `softwareupdate` | La VM n'a pas d'accès sortant — l'IP statique n'a pas été saisie |
| Ansible : « Don't run this as root! » | Une tâche Homebrew a perdu son `become: false` (`ansible.cfg` active `become` globalement) |
| Terraform attend puis échoue à lire l'IP | Un `agent.enabled = true` a été réintroduit : il n'existe pas d'agent QEMU pour macOS |
