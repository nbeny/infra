terraform {
  required_providers {
    proxmox = {
      source = "bpg/proxmox"
    }
  }
}

# ---------------------------------------------------------------------------
#  Une VM du lab, clonee depuis un template golden construit par Packer.
#
#  Le template porte deja tout le logiciel (docker, kubernetes, outils Kali).
#  Cette ressource ne fait que le materialiser : dimensionnement, reseau et
#  identite via cloud-init. La configuration applicative de jour 2 revient a
#  Ansible.
# ---------------------------------------------------------------------------

resource "proxmox_virtual_environment_vm" "this" {
  name        = var.name
  node_name   = var.node_name
  vm_id       = var.vm_id
  description = var.description
  tags        = var.tags

  on_boot = var.on_boot
  started = var.started

  # Bloc omis quand aucun ordre n'est demande : Proxmox demarre alors la VM
  # apres toutes celles qui en ont un.
  dynamic "startup" {
    for_each = var.startup_order == null ? [] : [1]
    content {
      order    = var.startup_order
      up_delay = var.startup_up_delay
    }
  }

  # Sans cela, Terraform refuse de detruire une VM allumee.
  stop_on_destroy = true

  # JAMAIS de redemarrage decide par le fournisseur. Par defaut il relance la
  # VM des qu'un changement l'exige (ballon, drapeau de disque...) -- pour la
  # VM 111, c'est tout le site coupe au moment ou l'apply se termine. Un
  # changement de materiel reste donc EN ATTENTE cote Proxmox (`qm config
  # --current` vs `qm config`) jusqu'a un `qm shutdown` / `qm start` choisi.
  reboot_after_update = false

  # `clone` ne sert qu'a la CREATION : apres coup, la VM ne garde aucun lien
  # avec son template (clone complet). Le fournisseur marque pourtant toute
  # difference dans ce bloc « forces replacement ». Mesure le 2026-10-09 : le
  # disque de la VM 111 avait ete deplace de pool2 vers pool1 hors Terraform,
  # l'etat retenait `clone.datastore_id = pool2`, et le plan proposait de
  # DETRUIRE la production pour la recloner -- quel que soit le changement
  # demande. L'emplacement reel des disques est porte par les blocs `disk`.
  lifecycle {
    ignore_changes = [clone]
  }

  # Cloner un gros disque prend du temps : le defaut de 30 min ne suffit pas
  # pour une VM de plusieurs centaines de Gio sur ZFS.
  timeout_clone  = 3600
  timeout_create = 3600

  # Clone COMPLET : la VM ne garde aucune dependance au template. Reconstruire
  # le template avec Packer n'impacte donc pas les VMs deja deployees.
  clone {
    vm_id        = var.template_vm_id
    full         = true
    datastore_id = var.datastore_id
  }

  # L'agent est installe par le role `common` dans les templates golden. Il est
  # requis pour lire l'IP de la VM, pour l'arreter proprement et pour le
  # fsfreeze de vzdump.
  #
  # ⚠️ Le SOCLE 9000 ne l'a PAS : c'est l'image cloud brute, sans aucun paquet
  # ajoute. Une VM clonee de ce socle doit demarrer avec `agent = false`, sinon
  # l'apply echoue au bout de cinq minutes d'attente. Voir var.agent_enabled.
  agent {
    enabled = var.agent_enabled
    timeout = "5m"
  }

  operating_system {
    type = "l26"
  }

  cpu {
    cores   = var.cores
    sockets = var.sockets
    type    = var.cpu_type
  }

  # `floating = 0` desactive le ballooning : la VM prend son allocation et ne
  # la rend jamais. Cote hote, le processus KVM garde en resident tout ce que
  # l'invite a touche une fois -- y compris son cache disque -- meme apres
  # liberation dans l'invite. C'est ce qui fait qu'une VM "parait pleine"
  # vue de l'hote alors qu'elle ne l'est pas.
  #
  # Mettre `memory_floating` a une valeur inferieure a `memory` active le
  # ballon : l'hote peut alors reprendre la memoire inutilisee entre les deux.
  # A manier avec precaution sur un noeud Kubernetes : kubelet calcule ses
  # seuils d'eviction sur la memoire totale vue au demarrage, et un ballon qui
  # se gonfle sous sa charge peut declencher des evictions.
  memory {
    dedicated = var.memory
    floating  = var.memory_floating
  }

  # Meme interface que dans le template : c'est ce qui permet de redimensionner
  # le disque clone au lieu d'en ajouter un second.
  disk {
    datastore_id = var.datastore_id
    interface    = "scsi0"
    size         = var.disk_size
    iothread     = true
    discard      = "on"
    # ⚠️ Une AFFIRMATION SUR LE MATERIEL, pas une optimisation -- elle se propage
    # jusqu'au noyau invite. Voir `variable "disk_ssd"` : ce drapeau valait
    # `true` en dur sur un noeud 100 % plateaux, et a fige un deploiement de
    # production 25 minutes le 2026-09-16.
    ssd = var.disk_ssd
  }

  # Second disque optionnel (voir var.extra_disk). Bloc dynamique : une VM qui
  # n'en declare pas n'en recoit aucun, et son plan reste vide.
  dynamic "disk" {
    for_each = var.extra_disk == null ? [] : [var.extra_disk]
    content {
      datastore_id = coalesce(disk.value.datastore, var.datastore_id)
      interface    = disk.value.interface
      size         = disk.value.size
      iothread     = true
      discard      = "on"
      # Meme drapeau, meme raison : voir le disque systeme ci-dessus. Le second
      # disque peut vivre sur un AUTRE stockage (etcd sur le SSD de local-lvm) :
      # sa verite materielle se declare donc a part, `extra_disk.ssd`.
      ssd = coalesce(disk.value.ssd, var.disk_ssd)
    }
  }

  # Attention : activer le pare-feu sur l'interface n'a d'effet que si le
  # pare-feu est active au niveau datacenter. Et le jour ou il l'est, une VM
  # marquee `firewall = true` SANS fichier /etc/pve/firewall/<vmid>.fw herite
  # de la politique par defaut (DROP) et devient injoignable. D'ou le `false`
  # par defaut : on n'active qu'apres avoir ecrit les regles de la VM.
  network_device {
    bridge   = var.bridge
    model    = "virtio"
    firewall = var.firewall
  }

  # Console serie : les images cloud n'ont pas de sortie VGA, elles ecrivent
  # sur ttyS0. Sans ces deux blocs, la console web reste noire.
  serial_device {
    device = "socket"
  }

  vga {
    type = "serial0"
  }

  # Il n'y a pas de serveur DHCP sur le bridge du lab : l'IP statique est
  # obligatoire, pas un confort.
  # L'interface doit correspondre au lecteur cloud-init deja present dans le
  # template golden, sinon Proxmox refuse ("cloud-init drive is already
  # attached at ..."). Packer place le sien sur ide0.
  initialization {
    datastore_id = var.datastore_id
    interface    = var.cloud_init_interface
    # Explicite, pas laisse au defaut : Proxmox derive l'instance-id cloud-init
    # d'un condensat de cette configuration. Un `ciupgrade` qui bascule change
    # l'instance-id, et au boot suivant cloud-init se croit sur une machine
    # neuve -- cles d'hote SSH regenerees, mise a niveau des paquets (kubelet
    # compris) sur un noeud de production.
    upgrade = false

    ip_config {
      ipv4 {
        address = "${var.ip}/${var.cidr_bits}"
        gateway = var.gateway
      }
    }

    dns {
      servers = var.dns_servers
      domain  = var.search_domain
    }

    user_account {
      username = var.admin_user
      keys     = var.ssh_public_keys
    }
  }
}
