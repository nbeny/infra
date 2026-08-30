# ---------------------------------------------------------------------------
#  Template golden Debian : docker + containerd + kubeadm/kubelet/kubectl
#
#  Entree  : template 9000 (tpl-debian-13-base), socle cloud-init Debian 13
#  Sortie  : template 9100 (tpl-debian-k8s), clone par Terraform
#
#    packer build -only='debian-k8s.*' .
#    packer build -only='debian-k8s.*' -force .     # reconstruire par-dessus
# ---------------------------------------------------------------------------

source "proxmox-clone" "debian-k8s" {

  # --- Connexion ------------------------------------------------------------
  proxmox_url              = var.proxmox_api_url
  username                 = var.proxmox_api_token_id
  token                    = var.proxmox_api_token_secret
  insecure_skip_tls_verify = var.proxmox_insecure
  node                     = var.proxmox_node

  # --- Source ---------------------------------------------------------------
  # Clone complet : le template de sortie ne doit dependre d'aucun socle,
  # sinon detruire 9000 casserait 9100.
  clone_vm_id = var.debian_base_template_id
  full_clone  = true

  # --- VM de build (devient le template en fin de build) --------------------
  vm_id    = var.debian_template_id
  vm_name  = "tpl-debian-k8s"
  cpu_type = "x86-64-v2-AES"
  cores    = 4
  sockets  = 1
  memory   = 4096
  os       = "l26"

  scsi_controller = "virtio-scsi-single"
  qemu_agent      = true

  network_adapters {
    bridge   = var.lab_bridge
    model    = "virtio"
    firewall = false
  }

  # --- cloud-init -----------------------------------------------------------
  # Le lecteur cloud-init herite du socle 9000 sert pendant le build (c'est lui
  # qui pose l'IP et la cle SSH), mais Packer le retire a la conversion en
  # template. `cloud_init = true` en rajoute un vierge apres coup : sans lui le
  # template n'a aucun lecteur cloud-init, et un `qm clone` manuel produit une
  # VM sans reseau. Terraform s'en sortirait (le provider en cree un), mais un
  # template doit rester clonable a la main.
  cloud_init              = true
  cloud_init_storage_pool = var.storage_pool

  ipconfig {
    ip      = "${var.debian_build_ip}/${var.lab_cidr_bits}"
    gateway = var.lab_gateway
  }

  # --- Template de sortie ---------------------------------------------------
  template_name        = "tpl-debian-k8s"
  template_description = "Debian 13 + docker + kubernetes ${var.kubernetes_version}. Construit par Packer -- ne pas modifier a la main."

  # --- SSH ------------------------------------------------------------------
  # ssh_host est impose : sans agent QEMU dans le socle, Packer ne peut pas
  # decouvrir l'IP tout seul, et on la connait deja via ipconfig.
  ssh_username           = var.debian_ssh_username
  ssh_private_key_file   = var.ssh_private_key_file
  ssh_host               = var.debian_build_ip
  ssh_timeout            = "15m"
  ssh_handshake_attempts = 60

  task_timeout = "20m"
}

build {
  name    = "debian-k8s"
  sources = ["source.proxmox-clone.debian-k8s"]

  # cloud-init tient le verrou dpkg pendant sa premiere execution : lancer
  # apt avant sa fin fait echouer le build de facon aleatoire.
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
    playbook_file = "${var.ansible_root}/playbooks/packer-debian-k8s.yml"
    user          = var.debian_ssh_username
    use_proxy     = false

    ansible_env_vars = [
      "ANSIBLE_HOST_KEY_CHECKING=False",
      "ANSIBLE_ROLES_PATH=${var.ansible_root}/roles",
      "ANSIBLE_PIPELINING=True",
      "ANSIBLE_NOCOLOR=1",
      "ANSIBLE_TIMEOUT=60",
    ]

    extra_arguments = [
      "-e", "kubernetes_version=${var.kubernetes_version}",
      "-e", "ansible_python_interpreter=/usr/bin/python3",
    ]
  }

  post-processor "manifest" {
    output     = "manifest-debian-k8s.json"
    strip_path = true
  }
}
