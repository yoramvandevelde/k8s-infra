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
proxmox_api_token = "root@pam!opentofu=<your-token>"
```

### 4. Deploy

```bash
cd tofu

# Download the Talos image to Proxmox first
tofu init
tofu apply -target=proxmox_download_file.talos

# Create the template (see step 2 above)

# Deploy the full cluster
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
| k8s-cp-1 | 10.10.30.101 | control-plane |
| k8s-cp-2 | 10.10.30.102 | control-plane |
| k8s-cp-3 | 10.10.30.103 | control-plane |
| k8s-w-1  | 10.10.30.104 | worker |
| k8s-w-2  | 10.10.30.105 | worker |

Control plane nodes also accept workloads (`allowSchedulingOnControlPlanes: true`).

## Destroying the cluster

```bash
tofu destroy
```

Note: the Talos template (VM 9003) and the downloaded image are not managed by OpenTofu and must be removed manually if needed.
