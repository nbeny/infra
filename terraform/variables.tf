# ---------------------------------------------------------------------------
#  Acces a l'API Proxmox
# ---------------------------------------------------------------------------

variable "pve_endpoint" {
  type        = string
  description = "URL de l'interface Proxmox, SANS le suffixe /api2/json."
  default     = "https://192.168.100.50:8006/"
}

variable "pve_api_token" {
  type        = string
  description = "Token API complet, au format utilisateur@realm!nom=secret. Cree par le playbook 00-proxmox-host.yml avec le tag `token`."
  sensitive   = true
}

variable "pve_insecure" {
  type        = bool
  description = "Ignorer la validation TLS (Proxmox utilise un certificat auto-signe par defaut)."
  default     = true
}

variable "pve_ssh_username" {
  type        = string
  description = "Utilisateur SSH sur le noeud, pour les operations que l'API ne couvre pas."
  default     = "root"
}

variable "pve_ssh_private_key_path" {
  type        = string
  description = "Cle privee utilisee pour ces operations SSH."
  default     = "/root/.ssh/id_rsa"
}

# ---------------------------------------------------------------------------
#  Templates golden produits par Packer
# ---------------------------------------------------------------------------

variable "templates" {
  type        = map(number)
  description = "Correspondance profil -> VMID du template golden."
  default = {
    "debian-k8s" = 9100
    "kali"       = 9101
  }
}

variable "default_datastore" {
  type        = string
  description = "Stockage par defaut des disques. `null` reprend pve_vm_storage depuis les group_vars Ansible."
  default     = null
}

# ---------------------------------------------------------------------------
#  Machines a deployer
# ---------------------------------------------------------------------------

variable "vms" {
  description = <<-EOT
    Machines du lab, indexees par nom. Le nom sert de nom d'hote Proxmox ET de
    nom d'inventaire Ansible : garde-le en minuscules, sans espace.

    Champs obligatoires : profile, vm_id, ip.
    Le profil determine le template clone (voir la variable `templates`).

    Exemple :
      vms = {
        "k8s-lab" = {
          profile   = "debian-k8s"
          vm_id     = 110
          ip        = "10.0.0.110"
          cores     = 4
          memory    = 8192
          disk_size = 64
        }
      }
  EOT

  type = map(object({
    profile     = string
    vm_id       = number
    ip          = string
    cores       = optional(number, 2)
    sockets     = optional(number, 1)
    memory      = optional(number, 4096)
    # 0 = pas de ballooning. Une valeur < memory laisse l'hote reprendre la
    # memoire inutilisee de la VM.
    memory_floating = optional(number, 0)
    disk_size       = optional(number, 32)
    datastore   = optional(string, null)
    on_boot     = optional(bool, true)
    started     = optional(bool, true)
    firewall    = optional(bool, false)
    description = optional(string, "")
    tags        = optional(list(string), [])
  }))

  default = {}

  validation {
    condition     = alltrue([for k, v in var.vms : contains(["debian-k8s", "kali"], v.profile)])
    error_message = "Chaque VM doit avoir un profile valant \"debian-k8s\" ou \"kali\"."
  }

  validation {
    condition     = alltrue([for k, v in var.vms : can(cidrhost("${v.ip}/32", 0))])
    error_message = "Chaque VM doit avoir une adresse IPv4 valide, sans prefixe (ex : \"10.0.0.110\")."
  }

  validation {
    condition     = length(distinct([for k, v in var.vms : v.vm_id])) == length(var.vms)
    error_message = "Deux VMs partagent le meme vm_id ; les VMID doivent etre uniques."
  }

  validation {
    condition     = length(distinct([for k, v in var.vms : v.ip])) == length(var.vms)
    error_message = "Deux VMs partagent la meme adresse IP."
  }

  # Les VMID 9000-9101 sont reserves aux templates. Les ecraser detruirait la
  # chaine de build.
  validation {
    condition     = alltrue([for k, v in var.vms : v.vm_id < 9000 || v.vm_id > 9999])
    error_message = "La plage 9000-9999 est reservee aux templates et aux VMs de build Packer."
  }
}

# ---------------------------------------------------------------------------
#  Machines macOS
#
#  Chaine differente de celle des VMs Linux, et volontairement separee :
#    Ansible (role pve_macos) construit la VM 9200
#      -> installation GRAPHIQUE manuelle, une seule fois (docs/macos-ci.md)
#      -> `qm template 9200`
#      -> Terraform clone depuis ce template
#
#  Il n'y a ni Packer ni cloud-init dans cette chaine : macOS ne supporte
#  aucun des deux.
#
#  RAPPEL MATERIEL : ce noeud (Xeon E5-2680, Sandy Bridge) n'a pas AVX2.
#  macOS Ventura et au-dela ne peuvent pas y demarrer. Monterey est le
#  plafond, ce qui plafonne Xcode a 14.2.
# ---------------------------------------------------------------------------

variable "macos_template" {
  type        = number
  description = "VMID du template macOS installe a la main."
  default     = 9200
}

variable "macos_osk" {
  type        = string
  description = <<-EOT
    Cle de 64 caracteres que renvoie le SMC des Macs Apple. macOS refuse de
    demarrer sans elle. Elle s'extrait d'un vrai Mac (voir docs/macos-ci.md)
    et n'est pas versionnee : la renseigner dans terraform.tfvars, ignore par
    git.

    Laisser vide si aucune VM macOS n'est declaree.
  EOT
  sensitive   = true
  default     = ""

  validation {
    condition     = var.macos_osk == "" || length(var.macos_osk) == 64
    error_message = "L'OSK fait exactement 64 caracteres."
  }
}

variable "macos_vms" {
  description = <<-EOT
    Machines macOS, indexees par nom.

    ATTENTION -- le champ `ip` est INFORMATIF. Il n'y a pas de cloud-init sur
    macOS et pas de DHCP sur vmbr1 : l'adresse est saisie a la main dans
    Preferences Systeme pendant l'installation du template. Ce champ ne sert
    qu'a generer l'inventaire Ansible et doit concorder avec l'invite.

    Exemple :
      macos_vms = {
        "macos-ci" = {
          vm_id     = 140
          ip        = "10.0.0.140"
          cores     = 4
          memory    = 8192
          disk_size = 200
        }
      }
  EOT

  type = map(object({
    vm_id     = number
    ip        = string
    cores     = optional(number, 4)
    sockets   = optional(number, 1)
    memory    = optional(number, 8192)
    disk_size = optional(number, 200)
    datastore = optional(string, "pool1")
    net_model = optional(string, "virtio")
    # `false` par defaut, a l'inverse des VMs Linux : le noeud est deja
    # surengage en memoire et macOS ne rend jamais la sienne (pas de ballon).
    on_boot     = optional(bool, false)
    started     = optional(bool, true)
    firewall    = optional(bool, false)
    description = optional(string, "")
    tags        = optional(list(string), [])
  }))

  default = {}

  validation {
    condition     = alltrue([for k, v in var.macos_vms : can(cidrhost("${v.ip}/32", 0))])
    error_message = "Chaque VM macOS doit avoir une adresse IPv4 valide, sans prefixe (ex : \"10.0.0.140\")."
  }

  validation {
    condition     = alltrue([for k, v in var.macos_vms : v.vm_id < 9000 || v.vm_id > 9999])
    error_message = "La plage 9000-9999 est reservee aux templates."
  }

  validation {
    condition     = length(distinct([for k, v in var.macos_vms : v.vm_id])) == length(var.macos_vms)
    error_message = "Deux VMs macOS partagent le meme vm_id."
  }

  # `vms` et `macos_vms` sont deux variables distinctes, mais elles peuplent le
  # MEME noeud Proxmox et le meme /24. Sans ces deux controles croises, un
  # VMID en double ferait echouer l'apply au milieu, et une IP en double
  # passerait totalement inapercue jusqu'a un conflit ARP en production.
  # (Terraform 1.9+ autorise ces references entre variables.)
  validation {
    condition = length(setintersection(
      toset([for k, v in var.macos_vms : v.vm_id]),
      toset([for k, v in var.vms : v.vm_id]),
    )) == 0
    error_message = "Un VMID est utilise a la fois dans `vms` et dans `macos_vms`."
  }

  validation {
    condition = length(setintersection(
      toset([for k, v in var.macos_vms : v.ip]),
      toset([for k, v in var.vms : v.ip]),
    )) == 0
    error_message = "Une adresse IP est utilisee a la fois dans `vms` et dans `macos_vms`."
  }

  # Une VM macOS declaree sans OSK produirait une VM qui panique au demarrage,
  # sans message exploitable. Autant refuser au plan.
  validation {
    condition     = length(var.macos_vms) == 0 || length(var.macos_osk) == 64
    error_message = "Des VMs macOS sont declarees mais `macos_osk` est vide. macOS ne demarre pas sans la reponse du SMC Apple (voir docs/macos-ci.md)."
  }
}

variable "generate_ansible_inventory" {
  type        = bool
  description = "Ecrire ansible/inventory/20-terraform.yml a chaque apply."
  default     = true
}
