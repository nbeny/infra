variable "name" {
  type        = string
  description = "Nom de la VM dans Proxmox. Sert aussi de nom d'inventaire Ansible."
}

variable "vm_id" {
  type        = number
  description = "VMID Proxmox. Doit etre libre et unique sur le noeud."
}

variable "node_name" {
  type        = string
  description = "Noeud Proxmox cible."
}

variable "template_vm_id" {
  type        = number
  description = "VMID du template macOS construit par le role Ansible pve_macos, puis installe a la main (9200 par defaut)."
}

variable "datastore_id" {
  type        = string
  description = "Stockage recevant le disque systeme."
}

# --- Dimensionnement --------------------------------------------------------

variable "cores" {
  type        = number
  description = "Coeurs par socket. DOIT etre une puissance de 2 : macOS panique au demarrage sinon."

  validation {
    condition     = contains([1, 2, 4, 8, 16], var.cores)
    error_message = "macOS exige un nombre de coeurs en puissance de 2 (1, 2, 4, 8, 16). Une valeur comme 6 provoque un kernel panic au demarrage."
  }
}

variable "sockets" {
  type        = number
  description = "Nombre de sockets CPU."
  default     = 1
}

variable "memory" {
  type        = number
  description = "Memoire dediee, en Mio. Le ballooning n'existe pas sur macOS : cette memoire est prise et gardee."
}

variable "disk_size" {
  type        = number
  description = "Taille du disque systeme en Gio. Ne peut qu'augmenter par rapport au template."
}

variable "cpu_type" {
  type        = string
  description = "Modele de CPU expose a l'invite. `host` est requis : macOS a besoin des drapeaux natifs du Xeon, et un modele generique le prive de SSE4.2."
  default     = "host"
}

# --- Reseau -----------------------------------------------------------------

variable "bridge" {
  type        = string
  description = "Bridge Proxmox de rattachement."
}

variable "net_model" {
  type        = string
  description = "Modele de carte reseau. macOS embarque un pilote VirtIO depuis Big Sur ; basculer sur `vmxnet3` si l'interface n'apparait pas dans Preferences Systeme."
  default     = "virtio"

  validation {
    condition     = contains(["virtio", "vmxnet3", "e1000"], var.net_model)
    error_message = "macOS ne pilote que virtio, vmxnet3 ou e1000."
  }
}

variable "ip" {
  type        = string
  description = <<-EOT
    Adresse IPv4 de la VM, INFORMATIVE UNIQUEMENT.

    Il n'y a pas de cloud-init sur macOS et pas de serveur DHCP sur vmbr1 :
    cette adresse est saisie a la main dans Preferences Systeme pendant
    l'installation du template. Ce champ ne fait qu'alimenter l'inventaire
    Ansible -- il doit concorder avec ce qui est configure dans l'invite, et
    rien ici ne peut le verifier.
  EOT
}

# --- QEMU -------------------------------------------------------------------

variable "kvm_arguments" {
  type        = string
  description = "Ligne d'arguments QEMU bruts. Contient l'OSK du SMC Apple, sans laquelle macOS ne demarre pas. Voir docs/macos-ci.md."
  sensitive   = true
}

# --- Divers -----------------------------------------------------------------

variable "description" {
  type        = string
  description = "Note affichee dans l'interface Proxmox."
  default     = ""
}

variable "tags" {
  type        = list(string)
  description = "Etiquettes Proxmox."
  default     = []
}

variable "on_boot" {
  type        = bool
  description = "Demarrer automatiquement la VM au demarrage du noeud."
  default     = false
}

variable "started" {
  type        = bool
  description = "Etat souhaite de la VM."
  default     = true
}

variable "firewall" {
  type        = bool
  description = "Active le pare-feu Proxmox sur l'interface. Meme piege que pour les VMs Linux : sans /etc/pve/firewall/<vmid>.fw, la VM devient injoignable des que le pare-feu datacenter est actif."
  default     = false
}
