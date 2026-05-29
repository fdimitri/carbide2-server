#!/usr/bin/env bash
# Bring up a local k3d cluster for carbide2 development.
#
# The cluster mirrors what a kubeadm install would look like: k3s's bundled
# Traefik and local-path provisioner are disabled and we install our own via
# Helm. ServiceLB (klipper-lb) is left enabled because the alternative for
# dev (MetalLB) needs an L2 broadcast domain that WSL2 doesn't have, and
# leaving it on doesn't change any of OUR manifests (they just ask for
# type=LoadBalancer; some controller provides it).
#
# Idempotent: re-running is safe; it will skip a cluster that already exists
# and "helm upgrade --install" each chart.

set -euo pipefail

CLUSTER_NAME="${CLUSTER_NAME:-carbide-dev}"
HTTP_PORT="${HTTP_PORT:-8080}"
HTTPS_PORT="${HTTPS_PORT:-8443}"

log() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m!!\033[0m %s\n' "$*" >&2; }

require() {
  command -v "$1" >/dev/null 2>&1 || { warn "missing required tool: $1"; exit 1; }
}
require k3d
require kubectl
require helm
require docker

if ! docker info >/dev/null 2>&1; then
  warn "docker daemon not reachable from this shell (group/socket issue?)"
  exit 1
fi

# --- cluster ----------------------------------------------------------------
if k3d cluster list 2>/dev/null | awk 'NR>1 {print $1}' | grep -qx "${CLUSTER_NAME}"; then
  log "cluster '${CLUSTER_NAME}' already exists, skipping creation"
else
  log "creating k3d cluster '${CLUSTER_NAME}' (HTTP ${HTTP_PORT} / HTTPS ${HTTPS_PORT})"
  k3d cluster create "${CLUSTER_NAME}" \
    --k3s-arg "--disable=traefik@server:*" \
    --k3s-arg "--disable=local-storage@server:*" \
    --port "${HTTP_PORT}:80@loadbalancer" \
    --port "${HTTPS_PORT}:443@loadbalancer" \
    --agents 0 \
    --wait
fi

log "kubectl context:"
kubectl config current-context
kubectl get nodes

# --- helm repos -------------------------------------------------------------
log "adding/updating helm repos"
helm repo add traefik https://traefik.github.io/charts >/dev/null 2>&1 || true
helm repo add cnpg https://cloudnative-pg.github.io/charts >/dev/null 2>&1 || true
helm repo update >/dev/null

# --- local-path-provisioner -------------------------------------------------
# Rancher's official manifest; same one k3s would have bundled. Installs into
# kube-system, registers a StorageClass named "local-path" and marks it default.
log "installing local-path-provisioner"
kubectl apply -f https://raw.githubusercontent.com/rancher/local-path-provisioner/v0.0.31/deploy/local-path-storage.yaml

# Make local-path the default StorageClass (idempotent).
kubectl annotate storageclass local-path \
  storageclass.kubernetes.io/is-default-class=true --overwrite >/dev/null

# --- traefik ----------------------------------------------------------------
log "installing traefik"
helm upgrade --install traefik traefik/traefik \
  --namespace traefik --create-namespace \
  --set ports.web.exposedPort=80 \
  --set ports.websecure.exposedPort=443 \
  --set service.type=LoadBalancer \
  --wait --timeout 3m

# --- cloudnative-pg operator -----------------------------------------------
log "installing cloudnative-pg operator"
helm upgrade --install cnpg cnpg/cloudnative-pg \
  --namespace cnpg-system --create-namespace \
  --wait --timeout 3m

# --- shared postgres cluster ------------------------------------------------
log "applying carbide postgres Cluster"
kubectl apply -f "$(dirname "$0")/../deploy/cnpg-cluster.yaml"

log "waiting for postgres cluster to be ready (may take ~60s on first run)..."
kubectl -n carbide-system wait --for=condition=Ready cluster/carbide-pg --timeout=5m || {
  warn "postgres cluster not Ready yet; check 'kubectl -n carbide-system describe cluster carbide-pg'"
}

# --- summary ----------------------------------------------------------------
log "done"
cat <<EOF

Cluster:    ${CLUSTER_NAME}
HTTP:       http://localhost:${HTTP_PORT}
HTTPS:      https://localhost:${HTTPS_PORT}
kubeconfig: \$(k3d kubeconfig write ${CLUSTER_NAME})

Useful commands:
  kubectl get pods -A
  kubectl -n traefik get svc
  kubectl -n carbide-system get cluster,pods
  k3d cluster stop  ${CLUSTER_NAME}
  k3d cluster start ${CLUSTER_NAME}
  k3d cluster delete ${CLUSTER_NAME}

EOF
