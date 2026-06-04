#!/usr/bin/env bash
set -euo pipefail

# ──────────────────────────────────────────────────────────────────────────────
# Bootstrap boundary script
# ──────────────────────────────────────────────────────────────────────────────
#
# This script intentionally does only the minimum imperative bootstrap work
# required before GitOps can take over.
#
# Responsibilities:
#   1. Wait until the Talos/Kubernetes base cluster is usable.
#   2. Install Cilium, because the cluster has no CNI yet.
#   3. Install ArgoCD, because ArgoCD is the GitOps entry point.
#   4. Restore the existing Sealed Secrets master key before the controller runs.
#   5. Start the Sealed Secrets controller.
#   6. Apply the root ArgoCD Application.
#
# Non-responsibilities:
#   - No platform component orchestration here.
#   - No app readiness checks here.
#   - No MetalLB/cert-manager/Kyverno/Tetragon logic here.
#   - No manual ArgoCD sync workarounds here.
#
# After root.yaml is applied, ArgoCD owns the cluster state.

# ── Config ────────────────────────────────────────────────────────────────────

GITOPS_DIR="/k8s-gitops"
KUBECONFIG="/output/kubeconfig"
TALOSCONFIG="/output/talosconfig"

SEALED_SECRETS_GPG="${GITOPS_DIR}/config/sealed-secrets-master-key.yaml.gpg"
SEALED_SECRETS_PASSPHRASE="${SEALED_SECRETS_PASSPHRASE:-}"

ARGOCD_NS="argocd"

# The Kubernetes API VIP is used by Cilium as the stable API endpoint.
# Cilium is installed before any GitOps-managed workloads can exist.
K8S_API_VIP="10.10.30.200"

CP_NODES="10.10.30.1,10.10.30.2,10.10.30.3"
CP_NODES_EXTRA="10.10.30.2,10.10.30.3"

WORKER_NODES="10.10.30.4,10.10.30.5,10.10.30.6,10.10.30.7,10.10.30.8"
INIT_NODE="10.10.30.1"

export KUBECONFIG
export TALOSCONFIG

# ── Helpers ───────────────────────────────────────────────────────────────────

retry() {
  local attempts=$1
  local delay=$2
  shift 2

  local n=1
  until "$@"; do
    if [ "$n" -ge "$attempts" ]; then
      return 1
    fi

    echo "→ Attempt ${n}/${attempts} failed, retrying in ${delay}s..."
    n=$((n + 1))
    sleep "${delay}"
  done
}

wait_for_nodes() {
  echo "→ Waiting for Kubernetes nodes to register..."

  # At this point nodes do not have to be Ready yet.
  # Before Cilium is installed, Kubernetes nodes may be visible as NotReady.
  # We only need the API server to know about them.
  until kubectl get nodes 2>/dev/null | grep -qE " Ready | NotReady "; do
    sleep 5
  done

  echo "→ Kubernetes nodes registered"
}

wait_for_etcd() {
  echo "→ Waiting for etcd on all control-plane nodes..."

  # This is a lightweight Talos-side etcd gate.
  # It prevents continuing while the control-plane storage layer is still
  # settling, without relying on Kubernetes-level controllers.
  until [ "$(
    talosctl --talosconfig "${TALOSCONFIG}" -n "${CP_NODES}" services \
      | awk '$2 == "etcd" && $3 == "Running" && $4 == "OK" { count++ } END { print count+0 }'
  )" = "3" ]; do
    echo "→ etcd not ready yet, retrying..."
    sleep 10
  done

  echo "→ etcd ready"
}

wait_for_kube_api() {
  echo "→ Waiting for Kubernetes API readiness..."

  # /readyz is a stricter API-server readiness check than simply being able
  # to open a TCP connection.
  until kubectl get --raw='/readyz' >/dev/null 2>&1; do
    echo "→ Kubernetes API not ready yet, retrying..."
    sleep 10
  done

  echo "→ Kubernetes API ready"
}

wait_for_talos_health() {
  echo "→ Waiting for full Talos cluster health..."

  # This validates the Talos/Kubernetes base cluster before installing
  # bootstrap components.
  #
  # Important:
  #   --nodes and --endpoints use a single Talos target.
  #   --init-node is separate.
  #   --control-plane-nodes must NOT include the init node, otherwise Talos
  #   discovers the init node twice and can fail node matching.
  until talosctl --talosconfig "${TALOSCONFIG}" health \
    --nodes "${INIT_NODE}" \
    --endpoints "${INIT_NODE}" \
    --control-plane-nodes "${CP_NODES_EXTRA}" \
    --worker-nodes "${WORKER_NODES}" \
    --init-node "${INIT_NODE}"; do
    echo "→ Talos cluster not healthy yet, retrying..."
    sleep 30
  done

  echo "→ Talos cluster healthy"
}

wait_for_deployment() {
  local ns=$1
  local name=$2

  echo "→ Waiting for deployment ${ns}/${name}..."

  kubectl wait --for=condition=available "deployment/${name}" \
    -n "${ns}" \
    --timeout=300s
}

# ── 1. Cilium ─────────────────────────────────────────────────────────────────

install_cilium() {
  echo "→ Installing Cilium..."

  # Cilium is installed directly instead of through ArgoCD because the cluster
  # has no working CNI yet. Without Cilium, normal workloads cannot become
  # healthy and ArgoCD cannot reliably manage the cluster.
  helm repo add cilium https://helm.cilium.io/ --force-update

  retry 3 20 helm upgrade --install cilium cilium/cilium \
    --namespace kube-system \
    --version "1.19.4" \
    --set k8sServiceHost="${K8S_API_VIP}" \
    --set k8sServicePort=6443 \
    --set kubeProxyReplacement=true \
    --set ipam.mode=kubernetes \
    --set routingMode=native \
    --set autoDirectNodeRoutes=true \
    --set ipv4NativeRoutingCIDR="10.244.0.0/16" \
    --set securityContext.capabilities.ciliumAgent="{CHOWN,KILL,NET_ADMIN,NET_RAW,IPC_LOCK,SYS_ADMIN,SYS_RESOURCE,DAC_OVERRIDE,FOWNER,SETGID,SETUID}" \
    --set securityContext.capabilities.cleanCiliumState="{NET_ADMIN,SYS_ADMIN,SYS_RESOURCE}" \
    --set cgroup.autoMount.enabled=false \
    --set cgroup.hostRoot=/sys/fs/cgroup \
    --set operator.replicas=1 \
    --wait \
    --timeout=5m
}

# ── 2. ArgoCD ─────────────────────────────────────────────────────────────────

install_argocd() {
  echo "→ Installing ArgoCD..."

  # ArgoCD is the handoff point from imperative bootstrap to declarative GitOps.
  # Everything after the root Application should be reconciled from Git.
  helm repo add argo https://argoproj.github.io/argo-helm --force-update

  kubectl create namespace "${ARGOCD_NS}" --dry-run=client -o yaml | kubectl apply -f -

  retry 5 20 helm upgrade --install argocd argo/argo-cd \
    --namespace "${ARGOCD_NS}" \
    --version "9.5.14" \
    --set configs.params."server\.insecure"=true \
    --set dex.enabled=false \
    --wait \
    --timeout=5m

  wait_for_deployment "${ARGOCD_NS}" "argocd-server"
}

# ── 3. Sealed Secrets ─────────────────────────────────────────────────────────

install_sealed_secrets_without_controller() {
  echo "→ Installing Sealed Secrets without controller..."

  # The existing Sealed Secrets private key must be restored before the
  # controller starts processing SealedSecret resources.
  #
  # If the controller starts first, it can generate a new keypair. Existing
  # SealedSecrets in Git would then fail to decrypt after ArgoCD syncs them.
  helm repo add sealed-secrets https://bitnami-labs.github.io/sealed-secrets --force-update

  retry 3 20 helm upgrade --install sealed-secrets sealed-secrets/sealed-secrets \
    --namespace kube-system \
    --version "2.18.5" \
    --set createController=false \
    --wait \
    --timeout=3m
}

import_sealed_secrets() {
  echo "→ Importing Sealed Secrets master key..."

  # The encrypted master key is stored in the GitOps repository, but the
  # passphrase is injected at bootstrap time from OpenTofu/container env.
  #
  # This keeps the raw private key out of Git while still allowing a fully
  # rebuildable cluster.
  test -n "${SEALED_SECRETS_PASSPHRASE}"
  test -f "${SEALED_SECRETS_GPG}"

  echo "${SEALED_SECRETS_PASSPHRASE}" \
    | gpg --batch --yes --passphrase-fd 0 -d "${SEALED_SECRETS_GPG}" \
    | kubectl apply -f -
}

start_sealed_secrets_controller() {
  echo "→ Starting Sealed Secrets controller..."

  # Now that the original key exists in the cluster, the controller can start
  # safely and decrypt existing SealedSecret resources from Git.
  retry 3 20 helm upgrade --install sealed-secrets sealed-secrets/sealed-secrets \
    --namespace kube-system \
    --version "2.18.5" \
    --set createController=true \
    --wait \
    --timeout=3m

  kubectl -n kube-system rollout status deploy/sealed-secrets --timeout=180s
}

# ── 4. Root App-of-Apps ───────────────────────────────────────────────────────

apply_root_app() {
  echo "→ Applying root App-of-Apps..."

  # This is the final imperative step.
  # From here on, ArgoCD reconciles bootstrap phases and applications from Git.
  kubectl apply -f "${GITOPS_DIR}/bootstrap/root.yaml"
}

# ── Main ──────────────────────────────────────────────────────────────────────

wait_for_nodes
wait_for_etcd
wait_for_kube_api
wait_for_talos_health

install_cilium
wait_for_kube_api

install_argocd

# ArgoCD Helm creates argocd-secret without the annotation SealedSecrets requires
# to take ownership. Adding it here lets the controller update it once platform-edge syncs.
kubectl annotate secret argocd-secret -n "${ARGOCD_NS}" \
  sealedsecrets.bitnami.com/managed=true --overwrite

install_sealed_secrets_without_controller
import_sealed_secrets
start_sealed_secrets_controller

apply_root_app

echo "Bootstrap complete"
