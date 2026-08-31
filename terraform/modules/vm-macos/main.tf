terraform {
  required_providers {
    proxmox = {
      source = "bpg/proxmox"
    }
  }
}

# ---------------------------------------------------------------------------
#  Une VM macOS du lab, clonee depuis le template 9200 construit par Ansible.
#
#  POURQUOI UN MODULE SEPARE DE ./modules/vm
#
#  Le module generique repose sur trois choses que macOS n'a pas :
#    - cloud-init      -> pas d'IP, pas de compte, pas de cle SSH injectee
#    - l'agent QEMU    -> Terraform ne peut ni lire l'IP ni eteindre proprement
#    - un template Packer, construit sans intervention humaine
#
#  Les melanger dans un seul module aurait impose de rendre conditionnels la
#  moitie de ses blocs, au risque de faire bouger les VMs Debian et Kali
#  existantes. macOS a son propre contrat : il a son propre module.
#
#  CONSEQUENCE A CONNAITRE : la configuration reseau de l'invite (adresse IP,
#  passerelle, DNS) est saisie A LA MAIN dans macOS pendant l'installation du
#  template. La variable `ip` de ce module ne la CONFIGURE PAS -- elle ne sert
#  qu'a alimenter l'inventaire Ansible. Les deux doivent concorder, et rien
#  ici ne peut le verifier.
# ---------------------------------------------------------------------------

resource "proxmox_virtual_environment_vm" "this" {
  name        = var.name
  node_name   = var.node_name
  vm_id       = var.vm_id
  description = var.description
  tags        = var.tags

  on_boot = var.on_boot
  started = var.started

  stop_on_destroy = true

  # Un clone complet de plusieurs centaines de Gio sur ZFS depasse largement
  # le defaut de 30 minutes.
  timeout_clone  = 7200
  timeout_create = 7200

  clone {
    vm_id        = var.template_vm_id
    full         = true
    datastore_id = var.datastore_id
  }

  # Il n'existe pas d'agent QEMU pour macOS. Laisser `enabled = true` ferait
  # attendre Terraform jusqu'au delai d'expiration a chaque operation, puis
  # echouer a lire l'IP. Proxmox retombe sur ACPI pour l'arret, ce que macOS
  # honore correctement.
  agent {
    enabled = false
  }

  # Proxmox n'a pas de profil macOS. Tout autre choix que `other` lui ferait
  # ajouter des options -- les enlightenments Hyper-V en particulier -- qui
  # font paniquer le noyau XNU.
  operating_system {
    type = "other"
  }

  machine = "q35"
  bios    = "ovmf"

  cpu {
    cores   = var.cores
    sockets = var.sockets
    type    = var.cpu_type
  }

  # macOS n'a pas de pilote virtio-balloon : `floating` doit rester egal a
  # `dedicated`, sinon l'hote croit pouvoir reprendre de la memoire que
  # l'invite ne lui rendra jamais.
  memory {
    dedicated = var.memory
    floating  = var.memory
  }

  # Seul le disque systeme est declare. Le disque EFI et OpenCore (ide2) sont
  # herites du template : les redeclarer ici ferait recreer la VM a chaque
  # `apply`, comme dans le module generique ou seul scsi0 est declare.
  disk {
    datastore_id = var.datastore_id
    interface    = "virtio0"
    size         = var.disk_size
    discard      = "on"
    cache        = "unsafe"
  }

  network_device {
    bridge   = var.bridge
    model    = var.net_model
    firewall = var.firewall
  }

  # Pas de console serie : contrairement aux images cloud Linux, macOS ecrit
  # sur une sortie graphique. `vmware` est le seul modele que macOS pilote
  # sans pilote tiers.
  vga {
    type = "vmware"
  }

  # macOS refuse de demarrer sans le SMC d'Apple emule. Le clone herite bien
  # de la ligne `args:` du template, mais la declarer ici la place sous
  # controle de Terraform : une modification manuelle sera detectee.
  kvm_arguments = var.kvm_arguments

  lifecycle {
    # L'installation de macOS n'est PAS reproductible automatiquement : elle
    # coute une session graphique manuelle. Contrairement a une VM Debian que
    # Terraform sait refabriquer en dix minutes, la detruire est une perte
    # seche. `prevent_destroy` transforme donc tout `destroy` ou toute
    # recreation implicite (disque retreci, changement de template) en erreur
    # explicite plutot qu'en suppression silencieuse.
    #
    # Pour retirer volontairement une VM macOS : commenter cette ligne, ou
    # `terraform state rm` puis `qm destroy` a la main.
    prevent_destroy = true

    precondition {
      condition     = var.kvm_arguments != ""
      error_message = "kvm_arguments est vide : la VM demarrerait sans SMC Apple emule et macOS paniquerait. Renseigner macos_kvm_arguments (il contient l'OSK)."
    }
  }
}
