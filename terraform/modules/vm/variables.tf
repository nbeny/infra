variable "name" {
  type        = string
  description = "Nom de la VM dans Proxmox. Sert aussi de nom d'hote et de nom d'inventaire Ansible."
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
  description = "VMID du template golden a cloner (9100 debian-k8s, 9101 kali)."
}

variable "datastore_id" {
  type        = string
  description = "Stockage recevant le disque et le lecteur cloud-init."
}

# --- Dimensionnement --------------------------------------------------------

variable "cores" {
  type        = number
  description = "Coeurs par socket."
}

variable "sockets" {
  type        = number
  description = "Nombre de sockets CPU."
}

variable "memory" {
  type        = number
  description = "Memoire dediee, en Mio."
}

variable "memory_floating" {
  type        = number
  description = "Plancher du ballooning, en Mio. 0 desactive le ballon (la VM garde toute son allocation cote hote). Une valeur inferieure a `memory` permet a l'hote de reprendre la memoire inutilisee."
  default     = 0
}

variable "disk_size" {
  type        = number
  description = "Taille du disque systeme en Gio. Ne peut qu'augmenter par rapport au template."
}

variable "cpu_type" {
  type        = string
  description = "Modele de CPU expose a l'invite."
  default     = "x86-64-v2-AES"
}

# --- Reseau -----------------------------------------------------------------

variable "bridge" {
  type        = string
  description = "Bridge Proxmox de rattachement."
}

variable "ip" {
  type        = string
  description = "Adresse IPv4 statique, sans le prefixe."
}

variable "cidr_bits" {
  type        = number
  description = "Longueur du prefixe reseau."
}

variable "gateway" {
  type        = string
  description = "Passerelle par defaut."
}

variable "dns_servers" {
  type        = list(string)
  description = "Resolveurs DNS pousses par cloud-init."
}

variable "search_domain" {
  type        = string
  description = "Domaine de recherche DNS."
}

# --- cloud-init -------------------------------------------------------------

variable "admin_user" {
  type        = string
  description = "Compte administrateur cree par cloud-init."
}

variable "ssh_public_keys" {
  type        = list(string)
  description = "Cles publiques autorisees sur le compte administrateur."
}

variable "cloud_init_interface" {
  type        = string
  description = "Interface du lecteur cloud-init. Doit correspondre a celle du template golden : Packer place la sienne sur ide0."
  default     = "ide0"
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
  default     = true
}

variable "started" {
  type        = bool
  description = "Etat souhaite de la VM."
  default     = true
}

variable "firewall" {
  type        = bool
  description = "Active le pare-feu Proxmox sur l'interface. N'activer qu'apres avoir ecrit /etc/pve/firewall/<vmid>.fw, sinon la VM devient injoignable des que le pare-feu datacenter est actif."
  default     = false
}
