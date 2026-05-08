# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo does

Provisions a 5-node Talos Linux Kubernetes cluster on Proxmox using OpenTofu, then bootstraps it with Cilium, ArgoCD, and Sealed Secrets via a Docker-based bootstrap script.

## Commands

All OpenTofu commands run from `tofu/`:

```bash
cd tofu

tofu init
tofu plan
tofu apply

# First-time only: download Talos image before creating the template VM
tofu apply -target=proxmox_download_file.talos

# Extract credentials after apply
tofu output -raw kubeconfig > ~/.kube/config-sifft
tofu output -raw talosconfig > ~/.talos/config
```

## Architecture

### Infrastructure layer (`tofu/`)

| File | Purpose |
|------|---------|
| `providers.tf` | Proxmox (`bpg/proxmox ~0.78`) and Talos (`siderolabs/talos ~0.10`) providers |
| `nodes.tf` | `local.nodes` map — single source of truth for node names, VMIDs, IPs, and roles |
| `main.tf` | Clones VM template 9003 for each node in `local.nodes` |
| `talos.tf` | Talos secrets, image factory schematic (with qemu-guest-agent/iscsi-tools/util-linux-tools extensions), per-node machine config patches, bootstrap, kubeconfig/talosconfig resources |
| `bootstrap.tf` | `null_resource` that writes credentials to `output/` and runs the Docker bootstrap container |
| `outputs.tf` | Sensitive `kubeconfig` and `talosconfig` outputs |
| `variables.tf` | `proxmox_api_token` and `sealed_secrets_passphrase` (both sensitive) |

Node IPs are in `10.10.30.0/24`. The cluster endpoint is `https://10.10.30.1:6443` (k8s-cp-1). CNI is disabled in Talos machine config — Cilium is installed by the bootstrap script.

### Bootstrap layer (`scripts/bootstrap.sh`)

Runs inside `ghcr.io/yoramvandevelde/bootstrap:1.0.0` with three volume mounts: `output/` (credentials), `scripts/`, and `k3s-gitops/`. Sequence:

1. Wait for nodes → Install Cilium 1.17.3 (kube-proxy replacement, native routing)
2. Wait for API server → Install ArgoCD 7.8.0
3. Install Sealed Secrets 2.17.2 → Import GPG-encrypted master key from `k3s-gitops/config/sealed-secrets-master-key.yaml.gpg`
4. Apply `k3s-gitops/bootstrap/root.yaml` (ArgoCD App-of-Apps)

### GitOps layer (`k3s-gitops/` submodule)

Git submodule pointing to `https://github.com/yoramvandevelde/k3s-gitops`. Contains the ArgoCD app definitions, Sealed Secrets master key, and all workload manifests. Directory structure: `apps/`, `bootstrap/`, `config/`, `infrastructure/`.

## Secrets

- `terraform.tfvars` — gitignored, contains `proxmox_api_token` and `sealed_secrets_passphrase`
- `.env` — gitignored
- `output/` — gitignored, written at apply time (kubeconfig, talosconfig)
- Sealed Secrets master key is stored GPG-encrypted in the submodule at `k3s-gitops/config/sealed-secrets-master-key.yaml.gpg`

## Node topology

| Node | VMID | IP | Role |
|------|------|----|------|
| k8s-cp-1 | 301 | 10.10.30.1 | controlplane |
| k8s-cp-2 | 302 | 10.10.30.2 | controlplane |
| k8s-cp-3 | 303 | 10.10.30.3 | controlplane |
| k8s-w-1  | 304 | 10.10.30.4 | worker |
| k8s-w-2  | 305 | 10.10.30.5 | worker |

Control plane nodes accept workloads (`allowSchedulingOnControlPlanes: true`). The Proxmox host is at `10.10.10.253:8006`, Proxmox node name is `pve`.

## Modifying nodes

Node definitions live exclusively in `tofu/nodes.tf`. Adding/removing nodes only requires editing that file — `main.tf`, `talos.tf`, and bootstrap all iterate over `local.nodes`.
