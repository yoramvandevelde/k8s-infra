#!/usr/bin/env bash
set -euo pipefail

# ── Config ────────────────────────────────────────────────────────────────────
GITOPS_DIR="/k8s-gitops"
KUBECONFIG="/output/kubeconfig"
TALOSCONFIG="/output/talosconfig"

SEALED_SECRETS_GPG="${GITOPS_DIR}/config/sealed-secrets-master-key.yaml.gpg"
SEALED_SECRETS_PASSPHRASE="${SEALED_SECRETS_PASSPHRASE:-}"

ARGOCD_NS="argocd"
K8S_API_VIP="10.10.30.200"

CP_NODES="10.10.30.1,10.10.30.2,10.10.30.3"

export KUBECONFIG
export TALOSCONFIG

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
  until kubectl get nodes 2>/dev/null | grep -qE " Ready | NotReady "; do
    sleep 5
  done
  echo "→ Kubernetes nodes registered"
}

wait_for_etcd() {
  echo "→ Waiting for etcd on all control-plane nodes..."

  until talosctl --talosconfig "${TALOSCONFIG}" -n "${CP_NODES}" services \
    | grep -E '^10\.10\.30\.[123][[:space:]]+etcd' \
    | grep -c 'Running[[:space:]]\+OK' \
    | grep -q '^3$'; do
    echo "→ etcd not ready yet, retrying..."
    sleep 10
  done

  echo "→ etcd ready"
}

wait_for_kube_api() {
  echo "→ Waiting for Kubernetes API readiness..."
  until kubectl get --raw='/readyz' >/dev/null 2>&1; do
    echo "→ Kubernetes API not ready yet, retrying..."
    sleep 10
  done
  echo "→ Kubernetes API ready"
}

wait_for_talos_health() {
  echo "→ Waiting for full Talos cluster health..."

  until talosctl --talosconfig "${TALOSCONFIG}" health \
    --nodes 10.10.30.1 \
    --endpoints "${CP_NODES}"; do
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

install_cilium() {
  echo "→ Installing Cilium..."
  helm repo add cilium https://helm.cilium.io/ --force-update

  retry 3 20 helm upgrade --install cilium cilium/cilium \
    --namespace kube-system \
    --version "1.17.3" \
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

install_argocd() {
  echo "→ Installing ArgoCD..."
  helm repo add argo https://argoproj.github.io/argo-helm --force-update

  kubectl create namespace "${ARGOCD_NS}" --dry-run=client -o yaml | kubectl apply -f -

  retry 5 20 helm upgrade --install argocd argo/argo-cd \
    --namespace "${ARGOCD_NS}" \
    --version "7.8.0" \
    --set configs.params."server\.insecure"=true \
    --wait \
    --timeout=5m

  wait_for_deployment "${ARGOCD_NS}" "argocd-server"
}

install_sealed_secrets_without_controller() {
  echo "→ Installing Sealed Secrets without controller..."
  helm repo add sealed-secrets https://bitnami-labs.github.io/sealed-secrets --force-update

  retry 3 20 helm upgrade --install sealed-secrets sealed-secrets/sealed-secrets \
    --namespace kube-system \
    --version "2.17.2" \
    --set createController=false \
    --wait \
    --timeout=3m
}

import_sealed_secrets() {
  echo "→ Importing Sealed Secrets master key..."

  test -n "${SEALED_SECRETS_PASSPHRASE}"
  test -f "${SEALED_SECRETS_GPG}"

  echo "${SEALED_SECRETS_PASSPHRASE}" \
    | gpg --batch --yes --passphrase-fd 0 -d "${SEALED_SECRETS_GPG}" \
    | kubectl apply -f -
}

start_sealed_secrets_controller() {
  echo "→ Starting Sealed Secrets controller..."

  retry 3 20 helm upgrade --install sealed-secrets sealed-secrets/sealed-secrets \
    --namespace kube-system \
    --version "2.17.2" \
    --set createController=true \
    --wait \
    --timeout=3m

  kubectl -n kube-system rollout status deploy/sealed-secrets --timeout=180s
}

apply_root_app() {
  echo "→ Applying root App-of-Apps..."
  kubectl apply -f "${GITOPS_DIR}/bootstrap/root.yaml"
}

# ── Main ──────────────────────────────────────────────────────────────────────
wait_for_nodes
wait_for_etcd
wait_for_kube_api

install_cilium

wait_for_talos_health
wait_for_kube_api

install_argocd

install_sealed_secrets_without_controller
import_sealed_secrets
start_sealed_secrets_controller

apply_root_app

echo "Bootstrap complete"
