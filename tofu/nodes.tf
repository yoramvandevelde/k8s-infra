# nodes.tf
locals {
  nodes = {
    "k8s-cp-1" = { vmid = 310, ip = "10.10.30.101", role = "controlplane" }
    "k8s-cp-2" = { vmid = 311, ip = "10.10.30.102", role = "controlplane" }
    "k8s-cp-3" = { vmid = 312, ip = "10.10.30.103", role = "controlplane" }
    "k8s-w-1"  = { vmid = 313, ip = "10.10.30.104", role = "worker" }
    "k8s-w-2"  = { vmid = 314, ip = "10.10.30.105", role = "worker" }
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
