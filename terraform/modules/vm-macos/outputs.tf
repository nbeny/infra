output "vm_id" {
  description = "VMID Proxmox de la VM creee."
  value       = proxmox_virtual_environment_vm.this.vm_id
}

output "name" {
  description = "Nom de la VM."
  value       = proxmox_virtual_environment_vm.this.name
}

output "ip" {
  description = "Adresse IPv4 declaree. Rappel : elle est configuree a la main dans macOS, pas par Terraform."
  value       = var.ip
}

# Pas d'equivalent de `ipv4_addresses` ici : il n'existe pas d'agent QEMU pour
# macOS, donc Proxmox ne remonte aucune adresse depuis l'invite. Le seul
# controle possible est un ping ou un SSH depuis le noeud.
