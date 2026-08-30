output "vm_id" {
  description = "VMID Proxmox de la VM creee."
  value       = proxmox_virtual_environment_vm.this.vm_id
}

output "name" {
  description = "Nom de la VM."
  value       = proxmox_virtual_environment_vm.this.name
}

output "ip" {
  description = "Adresse IPv4 statique configuree par cloud-init."
  value       = var.ip
}

output "ipv4_addresses" {
  description = "Adresses remontees par l'agent invite QEMU (utile pour verifier que l'agent repond)."
  value       = proxmox_virtual_environment_vm.this.ipv4_addresses
}
