# nodes.tf
locals {
  nodes = {
    "k8s-cp-1" = { vmid = 301, ip = "10.10.30.1", role = "controlplane" }
    "k8s-cp-2" = { vmid = 302, ip = "10.10.30.2", role = "controlplane" }
    "k8s-cp-3" = { vmid = 303, ip = "10.10.30.3", role = "controlplane" }
    "k8s-w-1"  = { vmid = 304, ip = "10.10.30.4", role = "worker" }
    "k8s-w-2"  = { vmid = 305, ip = "10.10.30.5", role = "worker" }
  }

  cp_nodes     = { for k, v in local.nodes : k => v if v.role == "controlplane" }
  worker_nodes = { for k, v in local.nodes : k => v if v.role == "worker" }

  node_configs = {
    for k, v in local.nodes : k => yamlencode({
      machine = {
        network = {
          hostname = k
          interfaces = [{
            interface = "eth0"
            addresses = ["${v.ip}/24"]
            routes = [{
              network = "0.0.0.0/0"
              gateway = "10.10.30.254"
            }]
          }]
          nameservers = ["10.10.20.53"]
        }
      }
    })
  }
}
