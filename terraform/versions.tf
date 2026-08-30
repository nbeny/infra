terraform {
  required_version = ">= 1.9.0"

  required_providers {
    proxmox = {
      source  = "bpg/proxmox"
      version = "~> 0.111"
    }
    local = {
      source  = "hashicorp/local"
      version = "~> 2.5"
    }
  }
}
