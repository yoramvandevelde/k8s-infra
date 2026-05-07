resource "proxmox_virtual_environment_vm" "talos" {
  for_each  = local.nodes
  name      = each.key
  vm_id     = each.value.vmid
  node_name = "pve"

  clone {
    vm_id = 9003
    full  = true
  }

  cpu {
    cores = 4
    type  = "host"
  }

  memory {
    dedicated = 8192
  }

  network_device {
    bridge = "vmbr0"
    model  = "virtio"
  }

  operating_system {
    type = "l26"
  }

  boot_order = ["scsi0"]

  agent {
    enabled = true
  }
}
