# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Repository structure

This repo has two layers:

- **`tofu/`** — OpenTofu (open-source Terraform fork) that provisions a Talos Linux Kubernetes cluster on Proxmox.
- **`k3s-gitops/`** — git submodule (separate repo at `github.com/yoramvandevelde/k3s-gitops`) managing cluster state via ArgoCD app-of-apps. Changes here must be committed and pushed to that repo before ArgoCD picks them up.

`output/` is gitignored and contains the generated `kubeconfig` and `talosconfig` after `tofu apply`.

## OpenTofu commands

All `tofu` commands run from the `tofu/` directory.

```bash
cd tofu
tofu init
tofu plan
tofu apply

# First-time only: download Talos image to Proxmox before creating the template
tofu apply -target=proxmox_download_file.talos

tofu destroy
```

Extract cluster credentials after apply:
```bash
tofu output -raw kubeconfig > ../output/kubeconfig
tofu output -raw talosconfig > ../output/talosconfig
```

`terraform.tfvars` is gitignored and must contain `proxmox_api_token` and `sealed_secrets_passphrase`.

## Bootstrap flow

`tofu apply` triggers a `null_resource` that runs `scripts/bootstrap.sh` inside a Docker container (`ghcr.io/yoramvandevelde/bootstrap:1.0.0`). The script installs in order:

1. **Cilium** (via Helm, directly — must come before any workloads because the cluster has no CNI)
2. **ArgoCD** (via Helm)
3. **Sealed Secrets** (via Helm), then imports the GPG-encrypted master key from `k3s-gitops/config/sealed-secrets-master-key.yaml.gpg`
4. **Root app-of-apps** (`kubectl apply -f bootstrap/root.yaml`) — ArgoCD then self-manages everything else

The Sealed Secrets master key must be present before ArgoCD syncs; without it, all `SealedSecret` resources will fail to decrypt.

## ArgoCD app-of-apps structure

```
bootstrap/root.yaml           # Root Application — watches bootstrap/ dir
bootstrap/infrastructure.yaml # Application for infrastructure/ (recursive)
bootstrap/apps.yaml           # Application for apps/ (flat)
apps/*.yaml                   # One Application CRD per deployed app
```

The `infrastructure` Application excludes certain subdirectory files from its sync (cert-manager config, MetalLB config, storage configs, Kyverno policies) because they depend on CRDs that must be installed first. Those files are applied by a second sync wave or manually.

## Secrets

Seal a new secret without cluster access:
```bash
kubeseal --cert k3s-gitops/config/sealed-secret-pub.crt --format yaml < secret.yaml > sealed-secret.yaml
```

The GPG-encrypted master key lives at `k3s-gitops/config/sealed-secrets-master-key.yaml.gpg`. Decrypt with the passphrase in `terraform.tfvars`.

## Cluster topology

| Node | IP | Role |
|------|-----|------|
| k8s-cp-1 | 10.10.30.101 | control-plane |
| k8s-cp-2 | 10.10.30.102 | control-plane |
| k8s-cp-3 | 10.10.30.103 | control-plane |
| k8s-w-1  | 10.10.30.104 | worker |
| k8s-w-2  | 10.10.30.105 | worker |

VIP: `10.10.30.200` (shared across control-plane nodes via Talos VIP config). Control-plane nodes also schedule workloads (`allowSchedulingOnControlPlanes: true`).

Talos Linux is immutable — no SSH. Use `talosctl` with `TALOSCONFIG=output/talosconfig` for node-level access.

## Kyverno policies (all Enforce mode)

All workloads must comply or ArgoCD sync will fail:

- Image tags must be pinned (no `latest`)
- All containers must define CPU and memory requests and limits (exceptions: infra namespaces + `cilium-spire` + `sealed-secrets`)
- Privileged containers are blocked (exceptions: Cilium, `kube-proxy`, democratic-csi node drivers)
- Containers must run with `runAsNonRoot: true` (exceptions: `kube-system`, `storage`, `metallb-system`, `cilium-spire`)
- Containers must set `readOnlyRootFilesystem: true` (exceptions: `ingress-nginx`, `kube-system`, `storage`, `metallb-system`, `cilium-spire`)

All application namespaces also require a `CiliumNetworkPolicy` with default-deny and explicit allow rules.

## App structure

Apps using multiple environments follow a kustomize base/overlay pattern. The ArgoCD Application CRD in `apps/` points directly to the overlay path (e.g., `apps/wordpress/overlays/prod`).
