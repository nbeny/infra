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

variable "generate_ansible_inventory" {
  type        = bool
  description = "Ecrire ansible/inventory/20-terraform.yml a chaque apply."
  default     = true
}
