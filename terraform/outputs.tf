output "vms" {
  description = "Recapitulatif des VMs gerees par Terraform."
  value = {
    for k, m in module.vm : k => {
      vm_id   = m.vm_id
      ip      = m.ip
      profile = var.vms[k].profile
      ssh     = "ssh ${local.admin_user}@${m.ip}"
    }
  }
}

output "ansible_inventory_path" {
  description = "Inventaire genere pour Ansible."
  value       = var.generate_ansible_inventory ? "ansible/inventory/20-terraform.yml" : "desactive"
}

# Bloc pret a coller dans ~/.ssh/config sur le poste client. Le ProxyJump fait
# transiter la connexion par le noeud Proxmox : les VMs de 10.0.0.0/24 ne sont
# pas routables depuis le LAN.
output "ssh_config" {
  description = "Configuration SSH ProxyJump a ajouter dans ~/.ssh/config."
  value = join("\n", concat(
    [
      "# --- lab proxmox (genere par terraform output ssh_config) ---",
      "Host pve",
      "    HostName ${replace(replace(var.pve_endpoint, "https://", ""), ":8006/", "")}",
      "    User root",
      "    Port 22",
      "",
    ],
    flatten([
      for k, v in var.vms : [
        "Host ${k}",
        "    HostName ${v.ip}",
        "    User ${local.admin_user}",
        "    ProxyJump pve",
        "",
      ]
    ]),
    [
      "# Repli : joindre n'importe quelle VM du lab par son IP",
      "Host 10.0.0.*",
      "    User ${local.admin_user}",
      "    ProxyJump pve",
      "    StrictHostKeyChecking accept-new",
    ]
  ))
}

output "next_steps" {
  description = "Ce qu'il reste a faire apres l'apply."
  value = length(var.vms) == 0 ? "Aucune VM declaree : renseigne la variable `vms` dans terraform.tfvars." : join("\n", [
    "VMs creees. Configure-les avec Ansible :",
    "",
    "  cd ../ansible",
    "  ansible guests -m ping",
    length(local.debian_vms) > 0 ? "  ansible-playbook playbooks/20-debian-k8s.yml" : "",
    length(local.kali_vms) > 0 ? "  ansible-playbook playbooks/21-kali.yml" : "",
  ])
}
