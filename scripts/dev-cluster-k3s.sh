#!/usr/bin/env bash
# Bring up a local k3s cluster for carbide2 development (the --kube-backend=k3s
# counterpart to dev-cluster-k3d.sh).
#
# Unlike k3d (k3s-in-Docker), this installs k3s directly on the host via the
# official get.k3s.io installer: containerd runs on the host, the node IS the
# host, and Traefik's LoadBalancer (klipper ServiceLB) binds the host's real
# :80/:443 — so there is no docker port remap and no separate node container.
# As with the k3d path, k3s's bundled Traefik and local-storage are disabled so
# we install our own via Helm; ServiceLB is left enabled to satisfy
# type=LoadBalancer without needing MetalLB.
#
# Idempotent: re-running is safe; it skips the k3s install when the node is
# already up and "helm upgrade --install"s each chart.
#
# Requires sudo (k3s installs a systemd service and writes root-owned files).

set -euo pipefail

CLUSTER_NAME="${CLUSTER_NAME:-carbide-dev}"
# k3s ServiceLB binds the Traefik Service's real ports on the host, so the
# browser reaches :80/:443 directly (no 8080/8443 docker remap like k3d).
HTTP_PORT="${HTTP_PORT:-80}"
HTTPS_PORT="${HTTPS_PORT:-443}"
# Pin the same k3s line k3d v5.8.3 ships, so both backends behave alike.
K3S_CHANNEL="${K3S_CHANNEL:-stable}"
# Optional self-hosted registry this node should trust+pull from. deploy.rb sets
# these in registry mode; unset = no registry (containerd-import path).
REGISTRY_HOST="${REGISTRY_HOST:-}"
REGISTRY_PORT="${REGISTRY_PORT:-5000}"
REGISTRY_CA="${REGISTRY_CA:-}"

log() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m!!\033[0m %s\n' "$*" >&2; }

require() {
  command -v "$1" >/dev/null 2>&1 || { warn "missing required tool: $1"; exit 1; }
}
require kubectl
require helm

if [[ $EUID -eq 0 ]]; then
  warn "run as your normal user, not root — this script uses sudo where needed."
  exit 1
fi

# Trust a self-hosted registry on this (primary) node: pin its CA in k3s
# registries.yaml so containerd can pull over TLS. Written before k3s starts so
# a fresh install picks it up; on an existing cluster we restart k3s.
configure_registry_trust() {
  local host="$1" port="$2" ca="$3"
  local endpoint="$host"
  [[ "$host" == *:* ]] || endpoint="$host:$port"
  if [[ ! -f "$ca" ]]; then
    warn "registry CA not found: $ca — skipping registry trust (pods may ImagePullBackOff)"
    return
  fi
  log "trusting registry $endpoint on this node (registries.yaml)"
  local ca_dest="/etc/rancher/k3s/carbide-registry-ca.pem"
  sudo mkdir -p /etc/rancher/k3s
  sudo install -m 0644 "$ca" "$ca_dest"
  sudo tee /etc/rancher/k3s/registries.yaml >/dev/null <<YAML
configs:
  "$endpoint":
    tls:
      ca_file: "$ca_dest"
YAML
  if systemctl is-active --quiet k3s 2>/dev/null; then
    log "restarting k3s to pick up registries.yaml"
    sudo systemctl restart k3s
  fi
}

if [[ -n "$REGISTRY_HOST" ]]; then
  configure_registry_trust "$REGISTRY_HOST" "$REGISTRY_PORT" "$REGISTRY_CA"
fi

# --- cluster ----------------------------------------------------------------
# "Already up" == a k3s systemd service that reports a Ready node. We can't just
# check `command -v k3s` because a half-installed/stopped k3s would pass that.
k3s_node_ready() {
  systemctl is-active --quiet k3s 2>/dev/null || return 1
  sudo k3s kubectl get nodes --no-headers 2>/dev/null | grep -qw Ready
}

if k3s_node_ready; then
  log "k3s already running with a Ready node, skipping install"
else
  log "installing k3s (${K3S_CHANNEL} channel) — disabling bundled traefik + local-storage"
  # --write-kubeconfig-mode 644 so non-root kubectl/helm can read the kubeconfig
  # we copy below. --disable mirrors the k3d path (we bring our own Traefik +
  # local-path); ServiceLB stays enabled for type=LoadBalancer.
  curl -sfL https://get.k3s.io | \
    INSTALL_K3S_CHANNEL="${K3S_CHANNEL}" \
    INSTALL_K3S_EXEC="--disable=traefik --disable=local-storage --write-kubeconfig-mode=644" \
    sh -s -
fi

# --- kubeconfig -------------------------------------------------------------
# k3s writes its kubeconfig to /etc/rancher/k3s/k3s.yaml (server 127.0.0.1:6443).
# Copy it to ~/.kube/config so plain `kubectl`/`helm` AND deploy.rb's kubeclient
# (which reads ~/.kube/config) all work without a KUBECONFIG env dance.
KUBECFG="$HOME/.kube/config"
log "syncing k3s kubeconfig -> ${KUBECFG}"
mkdir -p "$(dirname "$KUBECFG")"
sudo cat /etc/rancher/k3s/k3s.yaml > "$KUBECFG"
chmod 600 "$KUBECFG"

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
# Same install as the k3d path. On k3s the LoadBalancer Service is fronted by
# klipper ServiceLB, which binds these exposedPorts on the host itself — so the
# browser reaches :80/:443 with no docker port publishing.
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

# --- MinIO (object store + static tier for client builds) -------------------
# Holds every built SPA client at clients/<family>/<sha>/*. The dedicated
# static tier: Traefik routes /clients/ straight to the MinIO service (see the
# workspace chart IngressRoute), and the `clients` bucket is anonymous-read so
# assets serve without credentials. Clients are uploaded by the meta-repo
# scripts/build-client (and by deploy.rb for the pinned client).
log "applying MinIO (object store + client static tier)"
kubectl apply -f "$(dirname "$0")/../deploy/minio.yaml"

log "waiting for MinIO to be ready..."
kubectl -n carbide-system rollout status deploy/minio --timeout=3m || {
  warn "MinIO not Ready yet; check 'kubectl -n carbide-system describe deploy minio'"
}

# --- LM Studio relay --------------------------------------------------------
# On k3s (unlike k3d) pods reach the host directly on its LAN/node IP — there is
# no host.k3d.internal bridge, so the socat relay isn't used. Point the
# workspace chart's aiProxy.defaultUrl at the host IP (e.g. http://<host-ip>:1234/v1)
# if you run a local LLM. This is informational only.
HOST_IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
warn "k3s backend: no host.k3d.internal relay. For a host LLM, set the workspace"
warn "chart aiProxy.defaultUrl to your host, e.g. http://${HOST_IP:-<host-ip>}:1234/v1"

# --- summary ----------------------------------------------------------------
log "done"
cat <<EOF

Backend:    k3s (host-native)
Cluster:    ${CLUSTER_NAME}
HTTP:       http://localhost:${HTTP_PORT}
HTTPS:      https://localhost:${HTTPS_PORT}
kubeconfig: ${KUBECFG}  (copied from /etc/rancher/k3s/k3s.yaml)

Useful commands:
  kubectl get pods -A
  kubectl -n traefik get svc
  kubectl -n carbide-system get cluster,pods
  sudo systemctl stop  k3s
  sudo systemctl start k3s
  sudo /usr/local/bin/k3s-uninstall.sh   # tear the cluster down completely

Multi-node: join agent nodes to this server (run ON each agent, not here):
  # 1. token (keep secret) — read it here on the server:
  sudo cat /var/lib/rancher/k3s/server/node-token
  # 2. on the agent (see scripts/dev-agent-k3s.sh):
  K3S_URL=https://${HOST_IP:-<server-ip>}:6443 K3S_TOKEN=<token> \\
    ./scripts/dev-agent-k3s.sh --registry-host <server>:5000 --registry-ca ./carbide-rootCA.pem

EOF
