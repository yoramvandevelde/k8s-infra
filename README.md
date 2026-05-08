# k8s-infra

OpenTofu infrastructure for a Talos Linux Kubernetes cluster on Proxmox.

## Prerequisites

- [OpenTofu](https://opentofu.org) (`brew install opentofu`)
- [talosctl](https://www.talos.dev/latest/introduction/getting-started/) (`brew install siderolabs/tap/talosctl`)
- [kubectl](https://kubernetes.io/docs/tasks/tools/) (`brew install kubectl`)
- A Proxmox node with API access
- A Talos template VM (see below)

## Setup

### 1. Proxmox API token

Create an API token in Proxmox UI:
`Datacenter → Permissions → API Tokens → Add`

- User: `root@pam`
- Token ID: `opentofu`
- Privilege Separation: **unchecked**

Also assign the token permissions on your storage:
`Datacenter → Permissions → Add → API Token Permission`
- Path: `/storage/<your-datastore>`
- Role: `Administrator`

### 2. Create the Talos template

```bash
ssh root@<proxmox-host>

# Download the Talos image first via tofu apply -target (see step 4)
# Then create the template:
qm create 9003 --name talos-v1.13.0-template --memory 8192 --cores 4 \
  --net0 virtio,bridge=vmbr0 --scsihw virtio-scsi-pci --ostype l26 --agent enabled=1

qm importdisk 9003 /path/to/talos-v1.13.0.img <datastore>
qm set 9003 --scsi0 <datastore>:9003/vm-9003-disk-0.raw
qm set 9003 --boot order=scsi0
qm template 9003
```

### 3. Configure variables

```bash
cp tofu/terraform.tfvars.example tofu/terraform.tfvars
```

Edit `tofu/terraform.tfvars`:

```hcl
proxmox_api_token         = "root@pam!opentofu=<your-token>"
sealed_secrets_passphrase = "<gpg-passphrase-for-sealed-secrets-master-key>"
```

### 4. Deploy

```bash
cd tofu

# Download the Talos image to Proxmox first
tofu init
tofu apply -target=proxmox_download_file.talos

# Create the template (see step 2 above)

# Deploy the full cluster — also runs bootstrap.sh automatically
# which installs Cilium, ArgoCD, Sealed Secrets and applies the root app
tofu apply
```

## Accessing the cluster

### kubeconfig

```bash
tofu output -raw kubeconfig > ~/.kube/config-sifft
kubectl --kubeconfig ~/.kube/config-sifft get nodes
```

### talosconfig

```bash
tofu output -raw talosconfig > ~/.talos/config
talosctl get nodes
```

## Cluster topology

| Node | IP | Role |
|------|-----|------|
| k8s-cp-1 | 10.10.30.1 | control-plane |
| k8s-cp-2 | 10.10.30.2 | control-plane |
| k8s-cp-3 | 10.10.30.3 | control-plane |
| k8s-w-1  | 10.10.30.4 | worker |
| k8s-w-2  | 10.10.30.5 | worker |
| VIP | 10.10.30.200 | control-plane (shared) |

Control plane nodes share a VIP at `10.10.30.200` (configured via Talos). This is the Kubernetes API endpoint. Control plane nodes also accept workloads (`allowSchedulingOnControlPlanes: true`).

## Destroying the cluster

```bash
tofu destroy
```

Note: the Talos template (VM 9003) and the downloaded image are not managed by OpenTofu and must be removed manually if needed.
