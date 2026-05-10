variable "proxmox_api_token" {
  type      = string
  sensitive = true
}

variable "sealed_secrets_passphrase" {
  type      = string
  sensitive = true
}

variable "oidc_issuer_url" {
  type      = string
  sensitive = true
}

variable "oidc_client_id" {
  type      = string
  sensitive = true
}
