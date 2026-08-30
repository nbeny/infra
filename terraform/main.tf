# ---------------------------------------------------------------------------
#  Source unique de verite du reseau et des identites
#
#  Les valeurs communes au lab (bridge, passerelle, DNS, compte admin, cles
#  publiques) sont lues directement dans les group_vars d'Ansible. Terraform et
#  Ansible partagent ainsi un seul fichier : changer une cle SSH a un seul
#  endroit la propage aux deux outils.
#
#  Contrainte : all.yml doit rester du YAML pur, sans expression Jinja.
# ---------------------------------------------------------------------------

locals {
  lab = yamldecode(file("${path.module}/../ansible/inventory/group_vars/all.yml"))

  node_name       = local.lab.pve_node
  bridge          = local.lab.lab_bridge
  gateway         = local.lab.lab_gateway
  cidr_bits       = local.lab.lab_netmask_bits
  dns_servers     = local.lab.lab_dns_servers
  search_domain   = local.lab.lab_search_domain
  admin_user      = local.lab.lab_admin_user
  ssh_public_keys = local.lab.lab_ssh_public_keys

  datastore = coalesce(var.default_datastore, local.lab.pve_vm_storage)

  debian_vms = { for k, v in var.vms : k => v if v.profile == "debian-k8s" }
  kali_vms   = { for k, v in var.vms : k => v if v.profile == "kali" }
}

module "vm" {
  source   = "./modules/vm"
  for_each = var.vms

  name           = each.key
  vm_id          = each.value.vm_id
  node_name      = local.node_name
  template_vm_id = var.templates[each.value.profile]
  datastore_id   = coalesce(each.value.datastore, local.datastore)

  cores           = each.value.cores
  sockets         = each.value.sockets
  memory          = each.value.memory
  memory_floating = each.value.memory_floating
  disk_size       = each.value.disk_size

  bridge        = local.bridge
  ip            = each.value.ip
  cidr_bits     = local.cidr_bits
  gateway       = local.gateway
  dns_servers   = local.dns_servers
  search_domain = local.search_domain

  admin_user      = local.admin_user
  ssh_public_keys = local.ssh_public_keys

  on_boot  = each.value.on_boot
  started  = each.value.started
  firewall = each.value.firewall
  tags     = concat(each.value.tags, ["terraform", each.value.profile])

  description = coalesce(
    each.value.description != "" ? each.value.description : null,
    "Profil ${each.value.profile}. Gere par Terraform -- toute modification manuelle sera ecrasee."
  )
}

# ---------------------------------------------------------------------------
#  Inventaire Ansible
#
#  Les noms de groupes correspondent a ceux de inventory/00-static.yml :
#  Ansible fusionne les deux sources, et les group_vars s'appliquent aux VMs
#  creees ici sans configuration supplementaire.
# ---------------------------------------------------------------------------

resource "local_file" "ansible_inventory" {
  count = var.generate_ansible_inventory ? 1 : 0

  filename        = "${path.module}/../ansible/inventory/20-terraform.yml"
  file_permission = "0644"

  content = join("\n", [
    "---",
    "# Genere par Terraform (terraform/main.tf). NE PAS EDITER A LA MAIN :",
    "# ce fichier est reecrit a chaque `terraform apply` et ignore par git.",
    "# Les VMs creees a la main se declarent dans 00-static.yml.",
    "",
    yamlencode({
      debian_nodes = {
        hosts = { for k, v in local.debian_vms : k => {
          ansible_host = v.ip
          vm_id        = v.vm_id
        } }
      }
      kali_nodes = {
        hosts = { for k, v in local.kali_vms : k => {
          ansible_host = v.ip
          vm_id        = v.vm_id
        } }
      }
    }),
  ])

  depends_on = [module.vm]
}
