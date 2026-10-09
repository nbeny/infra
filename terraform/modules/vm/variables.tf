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

variable "disk_ssd" {
  type    = bool
  default = false

  description = <<-EOT
    Presenter les disques de la VM comme des SSD (`ssd=1` cote QEMU).

    ⚠️ **Ce drapeau est une AFFIRMATION SUR LE MATERIEL, pas une optimisation.**
    Il se propage jusqu'au noyau invite, qui lit `rotational 0` et applique aux
    files d'attente la cible de latence des SSD : `wbt_lat_usec = 2000`, soit
    2 ms. Un plateau a 7200 tr/min ne la tient jamais, alors le noyau etrangle
    les ecritures en permanence -- les ecrivains sont gares en `rq_qos_wait` et
    `/proc/pressure/io` s'installe au-dessus de 25 % de stalls complets.

    Il valait `true` en dur jusqu'au 2026-09-16, sur un noeud dont les CINQ
    disques physiques sont des plateaux (`lsblk -d -o ROTA` rend 1 partout,
    derriere un PERC H710). Consequence mesuree : les shims containerd ont rate
    leurs delais, containerd a perdu la tache de conteneurs pourtant vivants,
    kubelet a boucle sur `KillContainerError: DeadlineExceeded`, et plus aucun
    pod neuf n'a demarre pendant 25 minutes -- sans qu'aucune etape de la
    livraison ne soit rouge, le site restant debout sur les anciens replicas.

    Defaut `false` parce que c'est la VERITE de ce noeud aujourd'hui. Le jour ou
    un vrai SSD arrive, passer `disk_ssd = true` sur les VMs qui vivent dessus
    -- et seulement sur celles-la : c'est une propriete du stockage, pas une
    preference.

    ⚠️ Changer cette valeur sur une VM EXISTANTE demande un arret/relance pour
    que QEMU reconstruise le peripherique. Les VMs deja creees restent donc
    protegees par la regle udev du role Ansible `common`, qui desarme
    l'etranglement sans toucher au materiel.
  EOT
}

variable "extra_disk" {
  type = object({
    size      = number
    datastore = optional(string, null)
    interface = optional(string, "scsi1")
    ssd       = optional(bool, null) # null = var.disk_ssd
  })
  default     = null
  description = <<-EOT
    Second disque, optionnel. Sert a poser une charge sensible a la LATENCE sur
    un stockage different de celui du disque systeme -- typiquement la base
    etcd d'un noeud Kubernetes sur un SSD, quand le disque systeme vit sur des
    plateaux.

    ⚠️ Le declarer ICI plutot que de l'ajouter a la main avec `qm set` n'est pas
    une coquetterie : le fournisseur relit TOUS les disques de la VM lors du
    refresh. Un disque present sur la VM mais absent de la configuration est vu
    comme une derive, et le prochain `apply` le SUPPRIME -- avec la base etcd
    dessus, donc avec le cluster.

    Le formatage et le montage ne sont PAS faits ici : Terraform ne fait que du
    materiel. Voir le role Ansible correspondant.
  EOT
}

variable "scsi_hardware" {
  type        = string
  description = "Controleur SCSI. Le defaut reprend celui du fournisseur, deja inscrit dans l'etat des VMs existantes."
  default     = "virtio-scsi-pci"
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

variable "agent_enabled" {
  type        = bool
  description = <<-EOT
    Attendre l'agent QEMU a la creation. A laisser a `true` pour les templates
    golden (9100/9101), ou le role `common` a deja installe qemu-guest-agent.

    A passer a `false` pour une VM clonee du SOCLE cloud-init 9000 : l'image
    cloud de Debian ne contient PAS l'agent, et le fournisseur echouerait apres
    cinq minutes d'attente. Le repasser a `true` une fois `common` joue --
    l'agent sert aussi au fsfreeze de vzdump, donc a la coherence des
    sauvegardes.
  EOT
  default     = true
}

# ---------------------------------------------------------------------------
#  Ordre de demarrage
# ---------------------------------------------------------------------------
#  La RAM du noeud est SURENGAGEE : 118 Go promis aux VMs pour 110 Go
#  physiques. Tant que les invites ne touchent pas toute leur memoire, cela
#  passe -- mais un demarrage a froid les lance toutes en meme temps, et c'est
#  precisement le moment ou chacune en demande le plus.
#
#  Ordonner le demarrage transforme une ruee en file d'attente. Proxmox lance
#  d'abord les VMs qui ont un ordre, dans l'ordre croissant, puis toutes les
#  autres : une VM non ordonnee passe donc naturellement en dernier, sans qu'on
#  ait a la declarer.
variable "startup_order" {
  type        = number
  description = "Rang de demarrage Proxmox. `null` = demarre apres les VMs ordonnees."
  default     = null
}

variable "startup_up_delay" {
  type        = number
  description = "Secondes a attendre APRES avoir demarre cette VM, avant la suivante."
  default     = null
}
