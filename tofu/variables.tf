variable "proxmox_api_token" {
  type      = string
  sensitive = true
}

variable "sealed_secrets_passphrase" {
  type      = string
  sensitive = true
}
