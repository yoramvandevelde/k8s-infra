# k8s-infra

Personal homelab Kubernetes cluster running on Talos Linux, provisioned on Proxmox via OpenTofu. The goal is a fully declarative setup where the entire cluster can be torn down and rebuilt automatically — infrastructure included.

This repo has two layers:

- **`tofu/`** — OpenTofu that provisions the Talos cluster on Proxmox (VMs, networking, bootstrap)
- **`k8s-gitops/`** — git submodule ([git.sifft.io/yoram/k8s-gitops](https://git.sifft.io/yoram/k8s-gitops)) managing cluster state via ArgoCD

---

## Infrastructure

**Platform**
- [Cilium](https://cilium.io) — CNI with Hubble UI, Envoy proxy, and SPIRE for mTLS between workloads
- [MetalLB](https://metallb.universe.tf) — bare-metal load balancer (L2)
- [ingress-nginx](https://kubernetes.github.io/ingress-nginx) — ingress controller
- [cert-manager](https://cert-manager.io) — TLS certificates via Let's Encrypt (DNS-01 via Cloudflare)
- [democratic-csi](https://github.com/democratic-csi/democratic-csi) — iSCSI and NFS storage via TrueNAS
- [Sealed Secrets](https://github.com/bitnami-labs/sealed-secrets) — encrypted secrets safe to commit to Git
- [snapshot-controller](https://github.com/kubernetes-csi/external-snapshotter) — volume snapshots

**Policy & Security**
- [Kyverno](https://kyverno.io) — policy engine, all policies in Enforce mode (see [Security](#security))
- [Tetragon](https://tetragon.io) — eBPF-based runtime security observability

**Operations**
- [Argo Rollouts](https://argoproj.github.io/rollouts/) — progressive delivery (canary deployments)
- [metrics-server](https://github.com/kubernetes-sigs/metrics-server) — resource metrics API (`kubectl top`)
- [VPA](https://github.com/kubernetes/autoscaler/tree/master/vertical-pod-autoscaler) — resource recommendation (recommender only, no auto-mutation)
- [Goldilocks](https://goldilocks.docs.fairwinds.com) — dashboard for VPA recommendations
- [Reflector](https://github.com/emberstack/kubernetes-reflector) — mirrors Secrets and ConfigMaps across namespaces
- [Reloader](https://github.com/stakater/Reloader) — restarts pods when their ConfigMap or Secret changes

**Observability**
- [VictoriaMetrics k8s stack](https://victoriametrics.com) — metrics storage and collection
- [Grafana](https://grafana.com) — dashboards

**Apps**
- [Authentik](https://goauthentik.io) — identity provider (OIDC/SSO); first-time setup at `/if/flow/initial-setup/`
- [Harbor](https://goharbor.io) — container registry with Trivy scanning, Cosign support, and OIDC via Authentik
- [Headlamp](https://headlamp.dev) — Kubernetes web UI with OIDC login via Authentik
- [Populi](https://git.sifft.io/yoram/populi) — personal finance tracker
- [Recipit](https://github.com/yoramvandevelde/recipit) — personal recipe manager
- [Vault](https://www.vaultproject.io) — secrets management with Raft storage
- [Woodpecker CI](https://woodpecker-ci.org) — CI runner with Forgejo integration and Harbor image push

---

## Cluster topology

| Node | IP | Role |
|------|----|------|
| k8s-cp-1 | 10.10.30.1 | control-plane |
| k8s-cp-2 | 10.10.30.2 | control-plane |
| k8s-cp-3 | 10.10.30.3 | control-plane |
| k8s-w-1  | 10.10.30.4 | worker |
| k8s-w-2  | 10.10.30.5 | worker |
| k8s-w-3  | 10.10.30.6 | worker |
| VIP      | 10.10.30.200 | Kubernetes API (shared across control-plane) |

Control-plane nodes also schedule workloads (`allowSchedulingOnControlPlanes: true`). Talos Linux is immutable — no SSH access; use `talosctl` for node-level operations.

---

## Bootstrap

`tofu apply` provisions the VMs and runs `scripts/bootstrap.sh` inside a Docker container. The script hands off to GitOps in the minimum number of imperative steps:

1. **Wait** for Talos cluster health and etcd quorum
2. **Cilium** — installed via Helm directly (no CNI yet, so ArgoCD can't run)
3. **ArgoCD** — installed via Helm; then `argocd-secret` is annotated so Sealed Secrets can take ownership after sync
4. **Sealed Secrets** — installed without controller, GPG master key imported, controller started
5. **Root app** — `kubectl apply -f bootstrap/root.yaml`; ArgoCD owns everything from here

After step 5 all platform phases and apps converge automatically from Git.

---

## GitOps structure

The gitops repo (`k8s-gitops/`) uses a phase model. The root Application watches `bootstrap/` and deploys one Application per phase in sync-wave order:

```
bootstrap/
  root.yaml                   # Root Application, watches bootstrap/ dir
  platform-crds.yaml          # wave 0 — CRDs and controllers
  platform-config.yaml        # wave 1 — ClusterIssuers, StorageClasses, Kyverno policies, Cilium config
  platform-storage.yaml       # wave 2 — democratic-csi
  platform-edge.yaml          # wave 3 — ingress-nginx, ArgoCD ingress, OIDC
  platform-observability.yaml # wave 4 — VictoriaMetrics, Grafana
  apps.yaml                   # wave 10 — user applications

phases/<name>/                # Helm Applications + supporting resources per phase
apps/                         # One Application CRD per user-facing app
  <name>/                     # Namespace, NetworkPolicy, etc. for that app
config/                       # Sealed Secrets public cert + encrypted master key
```

Phase Applications use `retryStrategy` where needed to handle CRD ordering on cold start — for example, `platform-observability` keeps retrying while victoria-metrics installs its operator CRDs.

---

## Security

All workloads must comply with the following Kyverno policies (Enforce mode) or ArgoCD sync will fail:

| Policy | Rule | Exceptions |
|--------|------|------------|
| `disallow-latest-tag` | Image tags must be pinned | — |
| `require-resource-requests-limits` | All containers must define CPU/memory requests and limits | infra namespaces, `cilium-spire`, `sealed-secrets` |
| `block-privileged-containers` | Privileged containers blocked | Cilium, `kube-proxy`, democratic-csi node drivers |
| `require-non-root` | `runAsNonRoot: true` | `kube-system`, `storage`, `metallb-system`, `cilium-spire` |
| `require-readonly-rootfs` | `readOnlyRootFilesystem: true` | `ingress-nginx`, `kube-system`, `storage`, `metallb-system`, `cilium-spire` |

All application namespaces require a `CiliumNetworkPolicy` with default-deny and explicit allow rules. The `cilium-spire` namespace gets `pod-security.kubernetes.io/enforce: privileged` via Kyverno mutation (required for SPIRE hostPath volumes and host networking).

---

## Secrets

Secrets are encrypted with Sealed Secrets. New secrets can be sealed without cluster access:

```bash
kubeseal --cert k8s-gitops/config/sealed-secret-pub.crt --format yaml < secret.yaml > sealed-secret.yaml
```

The GPG-encrypted master key is at `k8s-gitops/config/sealed-secrets-master-key.yaml.gpg`. The passphrase lives in `tofu/terraform.tfvars` (gitignored).

---

## Prerequisites

- [OpenTofu](https://opentofu.org)
- [talosctl](https://www.talos.dev)
- [kubectl](https://kubernetes.io/docs/tasks/tools/)
- Proxmox node with API access
- TrueNAS for storage (iSCSI + NFS)

---

## Setup

### 1. Proxmox API token

In the Proxmox UI: `Datacenter → Permissions → API Tokens → Add`

- User: `root@pam`, Token ID: `opentofu`, Privilege Separation: **unchecked**

Add storage permission: `Datacenter → Permissions → Add → API Token Permission`
- Path: `/storage/<datastore>`, Role: `Administrator`

### 2. Create the Talos template VM

```bash
# On the Proxmox host, after downloading the image via tofu (step 4 below):
qm create 9003 --name talos-template --memory 8192 --cores 4 \
  --net0 virtio,bridge=vmbr0 --scsihw virtio-scsi-pci --ostype l26 --agent enabled=1

qm importdisk 9003 /path/to/talos.img <datastore>
qm set 9003 --scsi0 <datastore>:9003/vm-9003-disk-0.raw
qm set 9003 --boot order=scsi0
qm template 9003
```

### 3. Configure variables

```bash
cat > tofu/terraform.tfvars <<EOF
proxmox_api_token         = "root@pam!opentofu=<your-token>"
sealed_secrets_passphrase = "<gpg-passphrase>"
EOF
```

### 4. Deploy

```bash
cd tofu
tofu init

# Download Talos image to Proxmox first
tofu apply -target=proxmox_download_file.talos

# Create the template VM (step 2 above)

# Deploy cluster — provisions VMs, runs bootstrap.sh, hands off to ArgoCD
tofu apply
```

### 5. Access the cluster

```bash
# Extract credentials
tofu output -raw kubeconfig > ../output/kubeconfig
tofu output -raw talosconfig > ../output/talosconfig

# Use from the repo root
kubectl --kubeconfig output/kubeconfig get nodes
talosctl --talosconfig output/talosconfig -n 10.10.30.1 dashboard
```

---

## Teardown

```bash
tofu destroy
```

The Talos template VM and downloaded image are not managed by OpenTofu and must be removed from Proxmox manually if needed.
