# ============================================================================
#  Les VMs du lab -- VERSIONNE.
#
#  Terraform charge ce fichier tout seul (suffixe .auto.tfvars). Il ne contient
#  AUCUN secret : le token API et l'OSK macOS restent dans terraform.tfvars,
#  ignore par git (modele : terraform.tfvars.example).
#
#  Ne JAMAIS redeclarer `vms` dans terraform.tfvars : Terraform lit les
#  *.auto.tfvars APRES terraform.tfvars, et la derniere valeur gagne -- une
#  copie locale serait silencieusement ignoree.
#
#  Releve sur le noeud le 2026-10-09 : `terraform plan` ne propose rien sur
#  urbanlink, mail, wow-turtle et ci-runner avec ce fichier.
#
#  Convention : le dernier octet de l'IP est egal au VMID.
#  Reserve    : 9000-9999 (templates et VMs de build Packer).
# ============================================================================

vms = {

  # --- Stack applicatif UrbanLink -------------------------------------------
  # Dimensionne pour les manifests de kube/urbanlink : ~54 Gio de requests
  # memoire, ~69 Gio de LIMITS (dont 32 pour le seul nominatim) et ~548 Gio de
  # volumes une fois tous les composants demarres.
  #
  # Budget memoire : le noeud porte 314 Go depuis le 2026-10-04 (20 barrettes).
  # Le surengagement d'avant (121,5 Go promis pour 110) est leve ; les
  # planchers de ballooning de ci-runner, mail et wow-turtle restent en place
  # par hygiene.
  "urbanlink" = {
    profile = "debian-k8s"
    vm_id   = 111
    # Demarre en PREMIER, et laisse 90 s a Kubernetes pour se poser avant que la
    # VM suivante ne vienne disputer la memoire : c'est la plus grosse.
    startup_order    = 1
    startup_up_delay = 90
    ip               = "10.0.0.111"
    cores            = 12
    sockets          = 2     # 24 vCPU sur les 32 threads du noeud
    memory           = 98304 # 96 Go
    memory_floating  = 98304 # ballon actif jamais gonfle : stats memoire vues de l'invite (2026-10-09)
    disk_size        = 700
    # etcd SUR SSD. Le disque systeme est sur un pool de disques mecaniques, et
    # etcd fsync a chaque ecriture. Mesure sur 12 jours (alors sur pool2) :
    # 30 859 fsync du WAL au-dela de 8 ms, dont 7 au-dela de 8 s. Passe 5 s, le
    # controller-manager et le scheduler perdent leur bail et redemarrent en
    # boucle -- symptome d'une panne memoire, cause : la latence disque.
    #
    # `local-lvm` est le thinpool du SSD Intel DC S3610 du noeud. Le montage de
    # ce disque sur /var/lib/etcd est fait par le role `kubernetes`.
    extra_disk = {
      size      = 32
      datastore = "local-lvm"
      ssd       = true # seul vrai SSD du noeud
    }
    on_boot     = true
    tags        = ["app", "urbanlink"]
    description = "Cluster Kubernetes hebergeant le stack UrbanLink."
  }

  # --- Messagerie urbanlink.fr ---------------------------------------------
  # RECONSTRUCTION : le socle 9000 est l'image cloud brute de Debian, sans
  # qemu-guest-agent, et un premier apply avec `agent = true` echoue apres cinq
  # minutes d'attente. Creer la VM avec `agent = false`, jouer 40-mail-vm.yml
  # (le role `common` installe l'agent), puis :
  #
  #     qm set 140 --agent enabled=1 && qm stop 140 && qm start 140
  #
  # L'ARRET/DEMARRAGE est indispensable : Proxmox n'attache le peripherique
  # virtio-serial de l'agent qu'au demarrage, un `reboot` depuis l'invite ne
  # suffit pas. Repasser enfin `agent = true` ici -- sans quoi le prochain
  # apply redesactive l'agent, donc le fsfreeze de vzdump. Meme procedure pour
  # toute VM `debian-base` (ci-runner, wow-turtle).
  "mail" = {
    profile = "debian-base"
    vm_id   = 140
    # En second : c'est le service qui a des engagements exterieurs (SMTP).
    # ci-runner et wow-turtle n'ont volontairement PAS de rang : Proxmox
    # demarre apres toutes les VMs ordonnees celles qui n'en ont pas.
    startup_order    = 2
    startup_up_delay = 30
    ip               = "10.0.0.140"
    cores            = 2
    memory           = 8192
    memory_floating  = 4096
    disk_size        = 150
    agent            = true
    on_boot          = true
    tags             = ["mail"]
    description      = "Mailcow -- boites urbanlink.fr. Emission via le VPS Hostinger."
  }

  # --- Runners GitHub Actions + registre d'images du lab ---------------------
  # Montee a la main, recreee le 2026-10-04 (perte de pool2), importee dans
  # Terraform le 2026-10-09. Configuree par playbooks/35-ci-registry.yml.
  #
  # Les surcharges cloud-init ci-dessous reproduisent EXACTEMENT celles de la
  # VM d'origine : elles entrent dans l'instance-id, et le moindre ecart (une
  # cle, leur ordre) ferait regenerer les cles d'hote SSH au boot suivant.
  # Pour une VM reconstruite de zero, on peut les retirer et revenir aux
  # valeurs du lab (compte nbeny, cles de all.yml) -- en mettant alors a jour
  # `ansible_user` de ci-runner dans inventory/00-static.yml.
  "ci-runner" = {
    profile              = "debian-base"
    vm_id                = 130
    ip                   = "10.0.0.130"
    cores                = 8
    memory               = 16384
    memory_floating      = 4096
    disk_size            = 160
    agent                = true
    on_boot              = true
    admin_user           = "debian" # cloud-init d'origine : nbeny n'existe pas sur cette VM
    cloud_init_interface = "ide2"
    ssh_public_keys = [
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIJtDIzD15+UwiHK6YYUAoWKUdUtL7RvAUkpaNMKJNK0P pve-root@urbanlink-ops",
      "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAACAQCxdCJcurl06bHxslyeOcxDYQfbf4zqdBMU54iFjhRnO6R7lVdbTNYSh15vO+nPEvNwqsTWRYqDrZHru+O9k2ZCDY2MhESiC+yKJQU73l9MdkcHXdgf5teJaLNdyUs/mfyIrjMXGBd/DBWuxQ2OKVOBDhrQ4RBtVFNzqH+dwl9eEZiiHITP6zr8W85juO9IP728WvgkHnEITv0LqneZAo6068msBbZsVRWMMNO0eqV2UhSpEvk7CPNxOrHwHaV72zwRl9lS0RQTiMSVlb36vV7SdcfiFFqPp1T5fM2Y1cJTFRNfTirH7uUqx5j7MKeZhjE2T9MNw8IA6gf0s1k5wf5kmibaDaTUKLosvNc/kUOIa55zfrItJbkC90Pmhl88cqFjIg4jMr+sASlwWzCnqk/gykT8qwPi5ovvPfn4QyR/H/Rlgbj2gwQC7rsYeKmUzprs3B5vK06EasNCBc85uODRdHUWwsMc33t51XlkcW1bYhK11leahAsAv7852zjEMxs3YA9R/p6Ojlyo0zTuDByRXFj0oJOKpcRU8YUepNY4pLCQ1EL3m2DamJUlTjAEWwD3zoPnPvseI9WWEY4LURHXXsqwj/30FLEgd/rfVB6KO7ULjQvhZ/gX7yPJMJ4R6GcR2nyjT8ZsBRD92FEs80E3OOwTBpNruyuYFMZKdcGjYQ== nbeny@student.42.fr",
      "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAACAQDSUylZjvfpw8wg62j+RhkydI1wVHfqo9UETPXgxfCbM+WkqBzHq9leC9UpYwPtc8flbkB+j0M7k0bRUVrQi+oGjfxLhn/7SWD3GOLAPTQSpDWjG2CTA9nNCiB8wKbIO2LUUApaFMvPdezQvUi4YYaF/PZ4SNJgO8xgG5m5uYcxlLDsSAJq//xoff/6T9zsbCoHPiPm19PKm1PjIlha2O12kfVJcjVeC/vgGo4Yuzm8XLIqpgRFDdbUiJc59js7I5zRgAXUdXrY8QmuyGcE6ACb6/U8/a42harMNvJno9uRahQsct8pdBjmWRUn6meJx1n5gFM9e+Lgiv0xm3TIy4b3n3tL1Tr5sx+lv+OdCdtNHg2ik8BId9U5eHZcKp7ZJXXiw6/W7X/MFFxu5TXcFlm5n8PtzilBAIMRCEKdURyHxfJ3Ip4k8cy8q/jBBeMEjyYM5LZpuPErXxITytzTKxNvOO2Euh04v/+JJgm9yIxPheoMsNEuP8L0c4vXaISzl6WSl0kCjCB0CeDflsKPDed2qJUHj4Z9GkVF6HOWf5uLq0LOpotR9X7CisOUf0eRD89DQlulozV5g/h/v5LeLL0b+YHyuVfWIaEJfik/noBXuU7ahGiqdaAQOGxpsWPo960wURVgReGr0s6QhkgtciC1PiNT99ENliqDq8gnodrnMQ== root@pve",
      "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAACAQDVPJg8TExJ9JMLcDWGUlAkHwlNZBsbiBp/+lVoYASGSFL/FDaNI67BOYoCZOThv4C3FMGGiu9Z/3SkG7We7eSXKAf31sA3faRhY+5R0xEfA7TCkd1YbHubv7tj9NqEEtn8bivgLzWnE9FwLBmDFyy0WRrVGaCrVSN1jXUeQpC6RhQji+heiEkfQWPl66PJsbD03b6yWClY+DGtiMzNu9P3tRNHV1XtF8N4T3c4UWRUdEoZc/1fF2JZiSgiT/9BqGwgyb6lAx8XL2cZwYMPOz/8cJsm8L+FycZp9g5c2C+MSu3ny5QuUxsxUtpy7DVIQ80hMvSdqdy2C9NtfMee8XZg7nkyJc53KpEF7Atdnkfg+NNtUJwpsembV6iQkCUQSKwOiv4ol+4jHMXK2YenY2Ye92/STLqsrJsKRUemEKWDLlDbxnclX394rS3IvPEAfPT7CsD6uuvrp1UlFuuPFo5mKykdSQ/K1jjVrWbaHD27vLQkyOkfvOOuHbooypDEZU+p2ezvnbyBgdLi9XG6Xq4mwntTKUIyvnLTc6xHh+xtMxdU44wnEkIeoei3fjjMLMI8gqhjSsmsM/fkFXlG4lC+I16S+hGTMurfaWdAx7A40wnhRh66/Srs3iDTGBZYM3aL33I35EHpy+feGXDPdIi4e+2T7OzpMh35Cue3Y5jy3Q== nbeny@PC-Alesio",
      "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAACAQDWtjiHeGHHf7fipu5Wrr04fs3W7LjdZMqFhlqS2W/2Ofwf8dFS05NIJPq1zmH8etGyDMpxyYmOjQ8UUS3zujs3uuCmETWAP1haUt3Snk78riq7tbVGoaixHcXTERMIOQ9UFRphuuWsWHwalOAbSta1P4z/mDaWBk7K0nfMt81HmhPR5feY4CudZVD5dkH4y4AqVL1N1YPB/rctvphjqbkixP4LUwGB6XbLekDgPsPDc8CwB/Gb/9fu3ujDzDCywY7iDD0Ud6s/PNVNf2ADUc/4sGtTKtHDLLM7bEw+xAFh+qTHttZ8u6QTS+zR95Cxsg+BtviVG83m3QC7vfz/2VtsKHPxlzvgs+z1vHGlm+gL1MucANpLmSse+vtcvfvBjShtFrKh7N/MVTX1piP3PBGBm0z9r7poiP/10cicTXeb9hZLj3XsLxsjWjxYLbIVlNeXXgFmgJ3aealum0IeX4OC81drUkOxL2eaeY/jPUVFYVPxb36uGaMD7yR+miY4pIHcrbV+bScuVgvFMtcpH3hIMfMBmeqf/fKz9dXmVrYronyJqPoOkDl23FFwaI3gP3lEfYHx9J1R3wffNk3qJPuGlC9Ctvt1F3c1hLawMtTHHa78Cf3UqHI781ch/xK5pAnA9xawp2n/sCrcaP1n35Wk5h7xJdKiIph1M8Xe4pz44Q== root@pve",
    ]
    scsi_hardware     = "virtio-scsi-single"
    ansible_inventory = false # deja dans ci_nodes (00-static.yml)
    tags              = ["ci", "github-runner"]
    description       = "Runners GitHub Actions (UrbanConnct x3, folionbeny, FrouFolio) + registre du lab 10.0.0.130:5000. Recreee le 2026-10-04 (perte de pool2), importee dans Terraform le 2026-10-09."
  }

  # --- Serveur de jeu Turtle WoW 1.17.2 ------------------------------------
  # mangosd/realmd natifs, MariaDB 11.8, compiles depuis les sources de la
  # fuite : voir docs/turtle-wow.md. Expose en direct sur l'IP de la maison :
  # turtle.urbanlink.fr en DNS-only, Freebox -> MikroTik -> 10.0.0.150 sur
  # 3724 (realmd) et 8091 (monde).
  "wow-turtle" = {
    profile         = "debian-base"
    vm_id           = 150
    ip              = "10.0.0.150"
    cores           = 8
    memory          = 32768
    memory_floating = 8192
    disk_size       = 40
    agent           = false # socle 9000 sans agent, cf. bloc mail
    on_boot         = true
    # PAS base_nodes : c'est la cible des playbooks Mailcow (40-43).
    ansible_group = "game_nodes"
    tags          = ["game"]
    description     = "Turtle WoW 1.17.2 (mangosd/realmd natifs). turtle.urbanlink.fr"
  }

  # --- VMs de validation, eteintes -------------------------------------------
  # `on_boot = false` NE SUFFIT PAS : il ne regit que le demarrage du noeud.
  # L'etat courant est regi par `started`, dont le defaut est `true` ; sans
  # `started = false`, un simple apply les RALLUME.
  "test-k8s" = {
    profile     = "debian-k8s"
    vm_id       = 190
    ip          = "10.0.0.190"
    cores       = 4
    sockets     = 1
    memory      = 8192
    disk_size   = 64
    on_boot     = false
    started     = false
    tags        = ["test"]
    description = "VM jetable de validation. Supprimable sans consequence."
  }

  "kali-test" = {
    profile     = "kali"
    vm_id       = 120
    ip          = "10.0.0.120"
    cores       = 4
    memory      = 8192
    disk_size   = 100 # >= 64 : le template fait deja 64 Go
    on_boot     = false
    started     = false
    tags        = ["test", "offsec"]
    description = "VM Kali de validation. Supprimable sans consequence."
  }
}

# ---------------------------------------------------------------------------
#  Machines macOS -- aucune deployee
# ---------------------------------------------------------------------------
# Chaine differente des VMs Linux, ni Packer ni cloud-init : voir
# docs/macos-ci.md. L'OSK va dans terraform.tfvars (secret).
#
# macos_vms = {
#   "macos-ci" = {
#     vm_id     = 160
#     ip        = "10.0.0.160"   # INFORMATIF : saisi a la main dans macOS
#     cores     = 4              # puissance de 2 obligatoire
#     memory    = 8192           # sans ballooning : macOS ne rend rien
#     disk_size = 200            # Xcode ~40 Go + simulateurs 8-12 Go chacun
#     on_boot   = false
#     tags      = ["ci", "macos"]
#     description = "Runner de compilation Xcode. Plafonne a Xcode 14.2."
#   }
# }
