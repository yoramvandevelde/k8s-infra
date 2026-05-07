i#!/usr/bin/env bash
set -euo pipefail

# ── Config ────────────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
KUBECONFIG="${REPO_ROOT}/output/kubeconfig"
GITOPS_DIR="${REPO_ROOT}/k3s-gitops"
SEALED_SECRETS_GPG="${GITOPS_DIR}/config/sealed-secrets-master-key.yaml.gpg"
CP1="10.10.30.1"
ARGOCD_NS="argocd"

export KUBECONFIG

# ── Helpers ───────────────────────────────────────────────────────────────────
wait_for_nodes() {
  echo "→ Waiting for nodes..."
  until kubectl get nodes 2>/dev/null | grep -q "Ready"; do
    sleep 5
  done
  kubectl wait --for=condition=Ready node --all --timeout=300s
}

wait_for_deployment() {
  local ns=$1 name=$2
  echo "→ Waiting for ${name} in ${ns}..."
  kubectl wait --for=condition=available deployment/${name} \
    -n "${ns}" --timeout=300s
}

# ── 1. Cilium ─────────────────────────────────────────────────────────────────
install_cilium() {
  echo "→ Installing Cilium..."
  helm repo add cilium https://helm.cilium.io/ --force-update

  helm upgrade --install cilium cilium/cilium \
    --namespace kube-system \
    --version "1.17.3" \
    --set k8sServiceHost="${CP1}" \
    --set k8sServicePort=6443 \
    --set kubeProxyReplacement=true \
    --set ipam.mode=kubernetes \
    --set routingMode=native \
    --set autoDirectNodeRoutes=true \
    --set securityContext.capabilities.ciliumAgent="{CHOWN,KILL,NET_ADMIN,NET_RAW,IPC_LOCK,SYS_ADMIN,SYS_RESOURCE,DAC_OVERRIDE,FOWNER,SETGID,SETUID}" \
    --set securityContext.capabilities.cleanCiliumState="{NET_ADMIN,SYS_ADMIN,SYS_RESOURCE}" \
    --set cgroup.autoMount.enabled=false \
    --set cgroup.hostRoot=/sys/fs/cgroup \
    --wait --timeout=5m
}

# ── 2. ArgoCD ─────────────────────────────────────────────────────────────────
install_argocd() {
  echo "→ Installing ArgoCD..."
  helm repo add argo https://argoproj.github.io/argo-helm --force-update

  kubectl create namespace "${ARGOCD_NS}" --dry-run=client -o yaml | kubectl apply -f -

  helm upgrade --install argocd argo/argo-cd \
    --namespace "${ARGOCD_NS}" \
    --version "7.8.0" \
    --set configs.params."server\.insecure"=true \
    --wait --timeout=5m

  wait_for_deployment "${ARGOCD_NS}" "argocd-server"
}

# ── 3. Sealed Secrets ─────────────────────────────────────────────────────────
import_sealed_secrets() {
  echo "→ Importing Sealed Secrets master key..."
  kubectl create namespace sealed-secrets --dry-run=client -o yaml | kubectl apply -f -
  gpg -d "${SEALED_SECRETS_GPG}" | kubectl apply -f -
}

# ── 4. Root App-of-Apps ───────────────────────────────────────────────────────
apply_root_app() {
  echo "→ Applying root App-of-Apps..."
  kubectl apply -f "${GITOPS_DIR}/bootstrap/root.yaml"
}

# ── Main ──────────────────────────────────────────────────────────────────────
wait_for_nodes
install_cilium
install_argocd
import_sealed_secrets
apply_root_app

echo "✓ Bootstrap complete"
