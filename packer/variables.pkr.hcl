packer {
  required_plugins {
    proxmox = {
      version = ">= 1.2.0"
      source  = "github.com/hashicorp/proxmox"
    }
    ansible = {
      version = ">= 1.1.0"
      source  = "github.com/hashicorp/ansible"
    }
  }
}

# ---------------------------------------------------------------------------
#  Connexion a l'API Proxmox
# ---------------------------------------------------------------------------

variable "proxmox_api_url" {
  type        = string
  description = "URL de l'API Proxmox, suffixe /api2/json inclus."
  default     = "https://192.168.100.50:8006/api2/json"
}

variable "proxmox_api_token_id" {
  type        = string
  description = "Identifiant du token, au format utilisateur@realm!nom-du-token."
  default     = "terraform@pve!provider"
}

variable "proxmox_api_token_secret" {
  type        = string
  description = "Secret du token API (UUID). A fournir via lab.auto.pkrvars.hcl ou PKR_VAR_proxmox_api_token_secret."
  sensitive   = true
}

variable "proxmox_insecure" {
  type        = bool
  description = "Ignorer la validation du certificat TLS (certificat auto-signe par defaut sur Proxmox)."
  default     = true
}

variable "proxmox_node" {
  type        = string
  description = "Nom du noeud Proxmox cible."
  default     = "pve"
}

variable "storage_pool" {
  type        = string
  description = "Stockage recevant les disques des templates."
  default     = "pool2"
}

# ---------------------------------------------------------------------------
#  Reseau du lab
# ---------------------------------------------------------------------------

variable "lab_bridge" {
  type        = string
  description = "Bridge sur lequel les VMs de build sont branchees."
  default     = "vmbr1"
}

variable "lab_gateway" {
  type        = string
  description = "Passerelle du reseau du lab (le noeud Proxmox lui-meme)."
  default     = "10.0.0.1"
}

variable "lab_cidr_bits" {
  type        = number
  description = "Longueur du prefixe reseau du lab."
  default     = 24
}

# Ces IP ne sont utilisees que le temps du build. Il n'y a pas de serveur DHCP
# sur vmbr1 : une IP statique est obligatoire, sinon Packer ne peut pas se
# connecter en SSH a la VM de build.
variable "debian_build_ip" {
  type        = string
  description = "IP temporaire de la VM de build Debian."
  default     = "10.0.0.240"
}

variable "kali_build_ip" {
  type        = string
  description = "IP temporaire de la VM de build Kali."
  default     = "10.0.0.241"
}

# ---------------------------------------------------------------------------
#  Templates
# ---------------------------------------------------------------------------

variable "debian_base_template_id" {
  type        = number
  description = "VMID du socle cloud-init Debian, cree par ansible/playbooks/10-templates.yml."
  default     = 9000
}

variable "kali_base_template_id" {
  type        = number
  description = "VMID du socle cloud-init Kali, cree par ansible/playbooks/10-templates.yml."
  default     = 9001
}

variable "debian_template_id" {
  type        = number
  description = "VMID du template golden Debian produit par ce build."
  default     = 9100
}

variable "kali_template_id" {
  type        = number
  description = "VMID du template golden Kali produit par ce build."
  default     = 9101
}

# ---------------------------------------------------------------------------
#  SSH
# ---------------------------------------------------------------------------

variable "ssh_private_key_file" {
  type        = string
  description = "Cle privee correspondant a une des cles publiques injectees dans les socles."
  default     = "/root/.ssh/id_rsa"
}

variable "debian_ssh_username" {
  type        = string
  description = "Utilisateur cloud-init du socle Debian (ciuser du template 9000)."
  default     = "debian"
}

variable "kali_ssh_username" {
  type        = string
  description = "Utilisateur cloud-init du socle Kali (ciuser du template 9001)."
  default     = "kali"
}

# ---------------------------------------------------------------------------
#  Provisionnement Ansible
# ---------------------------------------------------------------------------

variable "ansible_root" {
  type        = string
  description = "Chemin absolu du repertoire ansible/ sur la machine qui execute Packer."
  default     = "/root/infra/ansible"
}

variable "kubernetes_version" {
  type        = string
  description = "Mineure Kubernetes installee dans l'image Debian."
  default     = "1.36"
}

variable "kali_metapackage" {
  type        = string
  description = "Metapackage Kali installe. kali-linux-everything installe tout mais depasse 100 Go."
  default     = "kali-linux-large"
}

variable "kali_install_gui" {
  type        = bool
  description = "Installer XFCE + xrdp dans l'image Kali (accessible par tunnel SSH)."
  default     = false
}
