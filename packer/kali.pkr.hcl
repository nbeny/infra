# ---------------------------------------------------------------------------
#  Template golden Kali : metapackage d'outils offensifs
#
#  Entree  : template 9001 (tpl-kali-base), socle cloud-init Kali
#  Sortie  : template 9101 (tpl-kali-tools), clone par Terraform
#
#    packer build -only='kali.*' .
#    packer build -only='kali.*' -var kali_metapackage=kali-linux-everything .
#
#  Compte plusieurs dizaines de minutes pour kali-linux-large, et plusieurs
#  heures pour kali-linux-everything.
# ---------------------------------------------------------------------------

source "proxmox-clone" "kali" {

  # --- Connexion ------------------------------------------------------------
  proxmox_url              = var.proxmox_api_url
  username                 = var.proxmox_api_token_id
  token                    = var.proxmox_api_token_secret
  insecure_skip_tls_verify = var.proxmox_insecure
  node                     = var.proxmox_node

  # --- Source ---------------------------------------------------------------
  clone_vm_id = var.kali_base_template_id
  full_clone  = true

  # --- VM de build ----------------------------------------------------------
  # Plus de CPU et de RAM que pour Debian : l'installation du metapackage
  # deballe des milliers de paquets, c'est le poste le plus long du build.
  vm_id    = var.kali_template_id
  vm_name  = "tpl-kali-tools"
  cpu_type = "x86-64-v2-AES"
  cores    = 6
  sockets  = 1
  memory   = 8192
  os       = "l26"

  scsi_controller = "virtio-scsi-single"
  qemu_agent      = true

  network_adapters {
    bridge   = var.lab_bridge
    model    = "virtio"
    firewall = false
  }

  # --- cloud-init -----------------------------------------------------------
  # Packer retire le lecteur cloud-init herite du socle en convertissant la VM
  # en template : `cloud_init = true` en rajoute un vierge, sans quoi le
  # template n'est pas clonable a la main (VM sans reseau).
  cloud_init              = true
  cloud_init_storage_pool = var.storage_pool

  ipconfig {
    ip      = "${var.kali_build_ip}/${var.lab_cidr_bits}"
    gateway = var.lab_gateway
  }

  # --- Template de sortie ---------------------------------------------------
  template_name        = "tpl-kali-tools"
  template_description = "Kali Linux + ${var.kali_metapackage}. Construit par Packer -- ne pas modifier a la main."

  # --- SSH ------------------------------------------------------------------
  ssh_username           = var.kali_ssh_username
  ssh_private_key_file   = var.ssh_private_key_file
  ssh_host               = var.kali_build_ip
  ssh_timeout            = "15m"
  ssh_handshake_attempts = 60

  task_timeout = "30m"
}

build {
  name    = "kali"
  sources = ["source.proxmox-clone.kali"]

  provisioner "shell" {
    inline = [
      "echo 'Attente de la fin de cloud-init...'",
      "sudo cloud-init status --wait || true",
      "sudo apt-get update -qq",
      "sudo apt-get install -y -qq python3 python3-apt",
      "echo 'Machine prete pour Ansible'",
    ]
  }

  provisioner "ansible" {
    playbook_file = "${var.ansible_root}/playbooks/packer-kali.yml"
    user          = var.kali_ssh_username
    use_proxy     = false

    ansible_env_vars = [
      "ANSIBLE_HOST_KEY_CHECKING=False",
      "ANSIBLE_ROLES_PATH=${var.ansible_root}/roles",
      "ANSIBLE_PIPELINING=True",
      "ANSIBLE_NOCOLOR=1",
      # L'installation du metapackage tourne en asynchrone cote invite : le
      # timeout SSH doit rester genereux le temps des sondages.
      "ANSIBLE_TIMEOUT=120",
    ]

    extra_arguments = [
      "-e", "packer_kali_metapackage=${var.kali_metapackage}",
      "-e", "packer_kali_gui=${var.kali_install_gui}",
      "-e", "ansible_python_interpreter=/usr/bin/python3",
    ]
  }

  post-processor "manifest" {
    output     = "manifest-kali.json"
    strip_path = true
  }
}
