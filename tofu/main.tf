resource "proxmox_virtual_environment_vm" "talos" {
  for_each  = local.nodes
  name      = each.key
  vm_id     = each.value.vmid
  node_name = "pve"
  stop_on_destroy = true

  clone {
    vm_id = 9003
    full  = true
  }

  cpu {
    cores = 8
    type  = "host"
  }

  memory {
    dedicated = 16384
  }

  disk {
    datastore_id = "data-disk"
    interface    = "scsi0"
    size         = 32
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
