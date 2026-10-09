output "vms" {
  description = "Recapitulatif des VMs gerees par Terraform."
  value = {
    for k, m in module.vm : k => {
      vm_id   = m.vm_id
      ip      = m.ip
      profile = var.vms[k].profile
      ssh     = "ssh ${coalesce(var.vms[k].admin_user, local.admin_user)}@${m.ip}"
    }
  }
}

output "macos_vms" {
  description = "Recapitulatif des VMs macOS. Rappel : l'IP est configuree dans l'invite, pas par Terraform."
  value = {
    for k, m in module.macos_vm : k => {
      vm_id = m.vm_id
      ip    = m.ip
      ssh   = "ssh ${local.admin_user}@${m.ip}"
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
        "    User ${coalesce(v.admin_user, local.admin_user)}",
        "    ProxyJump pve",
        "",
      ]
    ]),
    # Meme bloc pour les VMs macOS : le compte est celui cree pendant
    # l'installation graphique, et il doit porter le meme nom que
    # lab_admin_user pour que l'inventaire Ansible fonctionne tel quel.
    flatten([
      for k, v in var.macos_vms : [
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
  value = length(var.vms) + length(var.macos_vms) == 0 ? "Aucune VM declaree : renseigne `vms` ou `macos_vms` dans terraform.tfvars." : join("\n", [
    "VMs creees. Configure-les avec Ansible :",
    "",
    "  cd ../ansible",
    "  ansible guests -m ping",
    length(local.debian_vms) > 0 ? "  ansible-playbook playbooks/20-debian-k8s.yml" : "",
    length(local.kali_vms) > 0 ? "  ansible-playbook playbooks/21-kali.yml" : "",
    # Une VM macOS clonee demarre sur l'ecran de connexion, sans sshd : elle
    # ne repond a Ansible qu'apres une premiere ouverture de session et
    # l'activation de Partage > Connexion a distance.
    length(var.macos_vms) > 0 ? join("\n", [
      "",
      "  # macOS : ouvrir la session dans noVNC, activer Partage > Connexion a",
      "  # distance, et verifier l'IP saisie a la main. Ensuite :",
      "  ansible-playbook playbooks/22-macos-ci.yml",
    ]) : "",
  ])
}
