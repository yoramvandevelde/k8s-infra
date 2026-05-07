terraform {
  required_providers {
    proxmox = {
      source  = "bpg/proxmox"
      version = "~> 0.78"
    }
    
    talos = {
      source  = "siderolabs/talos"
      version = "~> 0.10"
    }
  }
}

provider "proxmox" {
  endpoint  = "https://10.10.10.253:8006"
  api_token = var.proxmox_api_token
  insecure  = true
}
