#!/usr/bin/env bash
set -euo pipefail

# ── Config ────────────────────────────────────────────────────────────────────
REPO_ROOT="/output/.."
GITOPS_DIR="/k8s-gitops"
KUBECONFIG="/output/kubeconfig"
TALOSCONFIG="/output/talosconfig"
SEALED_SECRETS_GPG="${GITOPS_DIR}/config/sealed-secrets-master-key.yaml.gpg"
SEALED_SECRETS_PASSPHRASE="${SEALED_SECRETS_PASSPHRASE:-}"
CP1="10.10.30.200"
ARGOCD_NS="argocd"

export TALOSCONFIG
export KUBECONFIG

# ── Helpers ───────────────────────────────────────────────────────────────────
wait_for_nodes() {
  echo "→ Waiting for nodes to register..."
  until kubectl get nodes 2>/dev/null | grep -q "NotReady\|Ready"; do
    sleep 5
  done
  echo "→ Nodes registered, proceeding..."
}

wait_for_apiserver() {
  echo "→ Waiting for API server to stabilize..."
  sleep 30
  until kubectl cluster-info 2>/dev/null | grep -q "is running"; do
    sleep 5
  done
  echo "→ API server ready"
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
    --set ipv4NativeRoutingCIDR="10.244.0.0/16" \
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
  echo "${SEALED_SECRETS_PASSPHRASE}" | gpg --batch --passphrase-fd 0 -d "${SEALED_SECRETS_GPG}" | kubectl apply -f -
}

install_sealed_secrets() {
  echo "→ Installing Sealed Secrets..."
  helm repo add sealed-secrets https://bitnami-labs.github.io/sealed-secrets --force-update

  helm upgrade --install sealed-secrets sealed-secrets/sealed-secrets \
    --namespace kube-system \
    --version "2.17.2" \
    --wait --timeout=3m
}

# ── 4. Root App-of-Apps ───────────────────────────────────────────────────────
apply_root_app() {
  echo "→ Applying root App-of-Apps..."
  kubectl apply -f "${GITOPS_DIR}/bootstrap/root.yaml"
}

# ── Main ──────────────────────────────────────────────────────────────────────
wait_for_nodes
install_cilium
wait_for_apiserver
install_argocd
install_sealed_secrets
import_sealed_secrets
apply_root_app

echo "Bootstrap complete"
