#!/usr/bin/env bash
# Join THIS host to an existing carbide2 k3s cluster as an AGENT (worker) node.
#
# The server node is brought up by deploy.rb (scripts/dev-cluster-k3s.sh) as a
# single-node k3s server; this script turns extra machines into agents so the
# cluster is multi-node. It installs k3s in agent mode pointing at that server
# and (for registry mode) trusts the self-hosted registry's CA so the agent's
# containerd can pull the workspace/shell images.
#
# Agents need very little: k3s bundles its own containerd, so there is NO docker,
# ruby, helm, kubectl, or mkcert to install here. That's why this is a small,
# dedicated script rather than the full scripts/setmeup.sh provisioner (which is
# for the deploy/server host).
#
# Prereqs on the agent:
#   - Linux with systemd (k3s runs as a systemd service).
#   - The server URL and node-token. On the SERVER, read the token with:
#       sudo cat /var/lib/rancher/k3s/server/node-token
#   - For registry mode: the deploy host's carbide-rootCA.pem copied here (scp).
#   - Network: the agent must reach the server on tcp/6443 (and the registry on
#     its port, default 5000).
#
# Usage:
#   K3S_URL=https://<server>:6443 K3S_TOKEN=<token> \
#     ./scripts/dev-agent-k3s.sh \
#       --registry-host <server>:5000 --registry-ca ./carbide-rootCA.pem
#   # or with flags instead of env:
#   ./scripts/dev-agent-k3s.sh --server-url https://<server>:6443 \
#       --token-file ./node-token --registry-host <server>:5000 \
#       --registry-ca ./carbide-rootCA.pem
#
# Idempotent: re-running restarts the existing agent (picks up config changes)
# rather than reinstalling.
#
# END-OF-HELP

set -euo pipefail

K3S_URL="${K3S_URL:-}"
K3S_TOKEN="${K3S_TOKEN:-}"
K3S_CHANNEL="${K3S_CHANNEL:-stable}"
REGISTRY_HOST="${REGISTRY_HOST:-}"
REGISTRY_PORT="${REGISTRY_PORT:-5000}"
REGISTRY_CA="${REGISTRY_CA:-}"

# Accept both --flag value and --flag=value forms.
while [[ $# -gt 0 ]]; do
  case "$1" in
    --server-url)    K3S_URL="$2";            shift 2 ;;
    --server-url=*)  K3S_URL="${1#*=}";       shift ;;
    --token)         K3S_TOKEN="$2";          shift 2 ;;
    --token=*)       K3S_TOKEN="${1#*=}";     shift ;;
    --token-file)    K3S_TOKEN="$(cat "$2")"; shift 2 ;;
    --token-file=*)  K3S_TOKEN="$(cat "${1#*=}")"; shift ;;
    --registry-host)   REGISTRY_HOST="$2";      shift 2 ;;
    --registry-host=*) REGISTRY_HOST="${1#*=}"; shift ;;
    --registry-port)   REGISTRY_PORT="$2";      shift 2 ;;
    --registry-port=*) REGISTRY_PORT="${1#*=}"; shift ;;
    --registry-ca)     REGISTRY_CA="$2";        shift 2 ;;
    --registry-ca=*)   REGISTRY_CA="${1#*=}";   shift ;;
    -h|--help)
      sed -n '2,/END-OF-HELP/p' "$0" | sed -e '/END-OF-HELP/d' -e 's/^# \{0,1\}//'
      exit 0
      ;;
    *) echo "dev-agent-k3s: unknown arg: $1 (try --help)" >&2; exit 1 ;;
  esac
done

# The shell only expands a leading ~ for bare words, not inside --flag=~/path.
# Expand it ourselves so the =form of file-path args works like the space form.
[[ "$REGISTRY_CA" == "~/"* ]] && REGISTRY_CA="$HOME/${REGISTRY_CA#\~/}"

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m!!\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31mxx\033[0m %s\n' "$*" >&2; exit 1; }

[[ $EUID -eq 0 ]] && die "run as your normal user, not root — this script uses sudo where needed."
command -v curl >/dev/null 2>&1 || die "curl not found — install it (apt-get install -y curl) and retry."
[[ -n "$K3S_URL" ]]   || die "missing server URL (K3S_URL or --server-url=https://<server>:6443)."
[[ -n "$K3S_TOKEN" ]] || die "missing node token (K3S_TOKEN, --token=, or --token-file=). On the server: sudo cat /var/lib/rancher/k3s/server/node-token"

# Trust the self-hosted registry on this node: pin its CA in k3s registries.yaml
# so containerd can pull over TLS. Written BEFORE the agent starts so a fresh
# install picks it up. Same shape as dev-cluster-k3s.sh / setmeup.sh.
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
  if systemctl is-active --quiet k3s-agent 2>/dev/null; then
    log "restarting k3s-agent to pick up registries.yaml"
    sudo systemctl restart k3s-agent
  fi
}

if [[ -n "$REGISTRY_HOST" ]]; then
  configure_registry_trust "$REGISTRY_HOST" "$REGISTRY_PORT" "$REGISTRY_CA"
fi

if systemctl is-active --quiet k3s-agent 2>/dev/null; then
  log "k3s-agent already running — restarting to pick up any config changes"
  sudo systemctl restart k3s-agent
else
  log "installing k3s agent (${K3S_CHANNEL}) joining ${K3S_URL}"
  # Presence of K3S_URL makes the installer set up an agent (not a server).
  curl -sfL https://get.k3s.io | \
    INSTALL_K3S_CHANNEL="${K3S_CHANNEL}" \
    K3S_URL="${K3S_URL}" \
    K3S_TOKEN="${K3S_TOKEN}" \
    sh -s -
fi

cat <<EOF

$(printf '\033[1;34m==>\033[0m') agent join initiated for ${K3S_URL}

Verify on the SERVER (this node should appear, STATUS Ready within ~30s):
  kubectl get nodes -o wide

Uninstall the agent on this node:
  sudo /usr/local/bin/k3s-agent-uninstall.sh

EOF
