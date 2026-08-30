provider "proxmox" {
  endpoint  = var.pve_endpoint
  api_token = var.pve_api_token
  insecure  = var.pve_insecure

  # Certaines operations de disque du provider passent par SSH et non par
  # l'API. Terraform s'executant sur le noeud lui-meme, root s'y connecte via
  # sa propre cle (le role pve_host garantit qu'elle est dans authorized_keys).
  ssh {
    agent       = false
    username    = var.pve_ssh_username
    private_key = file(var.pve_ssh_private_key_path)
  }
}
