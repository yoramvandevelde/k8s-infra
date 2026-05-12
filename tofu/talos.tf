# Secrets
resource "talos_machine_secrets" "cluster" {
  talos_version = "1.13.0"
}

data "talos_image_factory_extensions_versions" "this" {
  talos_version = "1.13.0"
  filters = {
    names = ["qemu-guest-agent", "iscsi-tools", "util-linux-tools"]
  }
}

# Schematic
resource "talos_image_factory_schematic" "this" {
  schematic = yamlencode({
    customization = {
      systemExtensions = {
        officialExtensions = data.talos_image_factory_extensions_versions.this.extensions_info[*].name
      }
    }
  })
}

# Download nocloud image to Proxmox
resource "proxmox_download_file" "talos" {
  content_type            = "iso"
  datastore_id            = "data-disk"
  node_name               = "pve"
  file_name               = "talos-v1.13.0.img"
  url                     = "https://factory.talos.dev/image/${talos_image_factory_schematic.this.id}/v1.13.0/nocloud-amd64.raw.gz"
  decompression_algorithm = "gz"
  overwrite               = false
}

# Machine configs
data "talos_machine_configuration" "controlplane" {
  cluster_name     = "k8s-sifft"
  cluster_endpoint = "https://10.10.30.200:6443"
  machine_type     = "controlplane"
  machine_secrets  = talos_machine_secrets.cluster.machine_secrets
}

data "talos_machine_configuration" "worker" {
  cluster_name     = "k8s-sifft"
  cluster_endpoint = "https://10.10.30.200:6443"
  machine_type     = "worker"
  machine_secrets  = talos_machine_secrets.cluster.machine_secrets
}

locals {
  common_patches = {
    for k, v in local.nodes : k => [
      yamlencode({
        machine = {
          network = {
            interfaces = [{
              interface = "eth0"
              addresses = ["${v.ip}/24"]
              routes = [{
                network = "0.0.0.0/0"
                gateway = "10.10.30.254"
              }]
              dhcp = false
            }]
            nameservers = ["10.10.20.53"]
          }
        }
      }),
      yamlencode({
        apiVersion = "v1alpha1"
        kind       = "HostnameConfig"
        hostname   = k
        auto       = "off"
      }),
      yamlencode({
        cluster = {
          network = {
            cni = {
              name = "none"
            }
          }
        }
      })
    ]
  }

  # Control plane nodes get the VIP on eth0 in addition to their own IP
  cp_patches = {
    for k, v in local.cp_nodes : k => concat(
      local.common_patches[k],
      [
        yamlencode({
          cluster = {
            allowSchedulingOnControlPlanes = true
            apiServer = {
              extraArgs = {
                oidc-issuer-url     = var.oidc_issuer_url
                oidc-client-id      = var.oidc_client_id
                oidc-username-claim = "preferred_username"
                oidc-username-prefix = "-"
                oidc-groups-claim   = "groups"
              }
            }
          }
        }),
        yamlencode({
          machine = {
            network = {
              interfaces = [{
                interface = "eth0"
                addresses = ["${v.ip}/24"]
                routes = [{
                  network = "0.0.0.0/0"
                  gateway = "10.10.30.254"
                }]
                dhcp = false
                vip = {
                  ip = "10.10.30.200"
                }
              }]
              nameservers = ["10.10.20.53"]
            }
          }
        }),
      ]
    )
  }

  worker_patches = {
    for k, v in local.worker_nodes : k => local.common_patches[k]
  }
}

# Config apply per node
resource "talos_machine_configuration_apply" "this" {
  for_each                    = local.nodes
  client_configuration        = talos_machine_secrets.cluster.client_configuration
  machine_configuration_input = each.value.role == "controlplane" ? data.talos_machine_configuration.controlplane.machine_configuration : data.talos_machine_configuration.worker.machine_configuration
  node                        = [for addrs in proxmox_virtual_environment_vm.talos[each.key].ipv4_addresses : addrs[0] if length(addrs) > 0 && addrs[0] != "127.0.0.1"][0]
  config_patches              = each.value.role == "controlplane" ? local.cp_patches[each.key] : local.worker_patches[each.key]
  depends_on                  = [proxmox_virtual_environment_vm.talos]
}

# Bootstrap
resource "talos_machine_bootstrap" "this" {
  client_configuration = talos_machine_secrets.cluster.client_configuration
  node                 = "10.10.30.1"
  depends_on           = [talos_machine_configuration_apply.this]
}

# Kubeconfig
resource "talos_cluster_kubeconfig" "this" {
  client_configuration = talos_machine_secrets.cluster.client_configuration
  node                 = "10.10.30.1"
  depends_on           = [talos_machine_bootstrap.this]
}

# Talosconfig
data "talos_client_configuration" "this" {
  cluster_name         = "k8s-sifft"
  client_configuration = talos_machine_secrets.cluster.client_configuration
  nodes                = [for k, v in local.nodes : v.ip]
  endpoints            = [for k, v in local.cp_nodes : v.ip]
}

