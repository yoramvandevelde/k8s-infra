resource "proxmox_virtual_environment_vm" "controlplane" {
  for_each        = local.cp_nodes
  name            = each.key
  vm_id           = each.value.vmid
  node_name       = "pve"
  stop_on_destroy = true

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

  disk {
    datastore_id = "data-disk"
    interface    = "scsi0"
    size         = 32
    cache        = "writeback"
  }

  network_device {
    bridge = "vmbr30"
    model  = "virtio"
  }

  operating_system {
    type = "l26"
  }

  vga {
    type   = "std"
    memory = 16
  }

  boot_order = ["scsi0"]

  agent {
    enabled = true
  }
}

resource "proxmox_virtual_environment_vm" "worker" {
  for_each        = local.worker_nodes
  name            = each.key
  vm_id           = each.value.vmid
  node_name       = "pve"
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
    cache        = "writeback"
  }

  network_device {
    bridge = "vmbr30"
    model  = "virtio"
  }

  operating_system {
    type = "l26"
  }

  vga {
    type   = "std"
    memory = 16
  }

  boot_order = ["scsi0"]

  agent {
    enabled = true
  }
}
