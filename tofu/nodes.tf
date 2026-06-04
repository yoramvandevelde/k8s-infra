# nodes.tf
locals {
  cp_nodes = {
    "k8s-cp-1" = { vmid = 301, ip = "10.10.30.1", role = "controlplane" }
    "k8s-cp-2" = { vmid = 302, ip = "10.10.30.2", role = "controlplane" }
    "k8s-cp-3" = { vmid = 303, ip = "10.10.30.3", role = "controlplane" }
  }

  worker_nodes = {
    "k8s-w-1" = { vmid = 304, ip = "10.10.30.4", role = "worker" }
    "k8s-w-2" = { vmid = 305, ip = "10.10.30.5", role = "worker" }
    "k8s-w-3" = { vmid = 306, ip = "10.10.30.6", role = "worker" }
    "k8s-w-4" = { vmid = 307, ip = "10.10.30.7", role = "worker" }
    "k8s-w-5" = { vmid = 308, ip = "10.10.30.8", role = "worker" }
  }

  nodes = merge(local.cp_nodes, local.worker_nodes)
}
