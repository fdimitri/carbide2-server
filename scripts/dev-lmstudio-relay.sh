#!/usr/bin/env bash
# scripts/dev-lmstudio-relay.sh
#
# Expose LM Studio (or any other localhost-bound OpenAI-compatible server) to
# the k3d cluster's workspace pods.
#
# WHY: On WSL2, LM Studio's "Serve on Local Network" toggle binds the Windows
# host's 0.0.0.0, but the WSL Linux side can ONLY reach LM Studio via
# 127.0.0.1 (the Windows-side LAN listener is firewalled off from WSL).
# Meanwhile, k3d pods can't reach WSL's 127.0.0.1 either — they live in their
# own netns inside a docker container.
#
# The bridge: k3d resolves `host.k3d.internal` to the docker bridge gateway
# IP, which IS reachable from inside WSL. So we run a socat relay on that
# gateway IP that forwards to 127.0.0.1.
#
# Usage:
#   ./scripts/dev-lmstudio-relay.sh             # start relay (default 11234 -> 1234)
#   ./scripts/dev-lmstudio-relay.sh stop        # stop relay
#   LISTEN_PORT=12345 ./scripts/dev-lmstudio-relay.sh
#
# Then point your seeded Agent rows at the relay:
#   kubectl -n ws-1 exec deploy/ws-1 -c workspace -- bundle exec rails runner \
#     'Agent.update_all(provider_url: "http://host.k3d.internal:11234/v1")'
#
# Note: port 1234 itself is usually blocked because WSL2's port-mirror
# proxy already holds it for the Windows host listener. Pick a port the
# Windows side isn't using (11234 default).

set -euo pipefail

CLUSTER="${K3D_CLUSTER:-carbide-dev}"
LISTEN_PORT="${LISTEN_PORT:-11234}"
TARGET_PORT="${TARGET_PORT:-1234}"
TARGET_HOST="${TARGET_HOST:-127.0.0.1}"
LOG="/tmp/lmstudio-relay.log"

cmd="${1:-start}"

# Find the bridge gateway IP for this k3d cluster.
NET="k3d-${CLUSTER}"
BIND_IP="$(docker network inspect "${NET}" 2>/dev/null \
  | awk -F'"' '/"Gateway":/ { print $4; exit }')"
if [[ -z "${BIND_IP}" ]]; then
  echo "error: docker network ${NET} not found. Is k3d cluster ${CLUSTER} up?" >&2
  exit 1
fi

case "${cmd}" in
  start)
    if pgrep -f "socat.*${BIND_IP}:${LISTEN_PORT}" >/dev/null; then
      echo "relay already running on ${BIND_IP}:${LISTEN_PORT}"
      exit 0
    fi
    command -v socat >/dev/null || {
      echo "socat not installed. Try: sudo apt-get install -y socat" >&2
      exit 1
    }
    nohup socat -d \
      "TCP-LISTEN:${LISTEN_PORT},bind=${BIND_IP},fork,reuseaddr" \
      "TCP:${TARGET_HOST}:${TARGET_PORT}" \
      > "${LOG}" 2>&1 &
    disown
    sleep 0.3
    echo "relay started: pods can reach LM Studio at"
    echo "  http://host.k3d.internal:${LISTEN_PORT}/v1"
    echo "log: ${LOG}"
    ;;
  stop)
    pkill -f "socat.*${BIND_IP}:${LISTEN_PORT}" && echo "stopped." || echo "not running."
    ;;
  status)
    if pgrep -f "socat.*${BIND_IP}:${LISTEN_PORT}" >/dev/null; then
      echo "running on ${BIND_IP}:${LISTEN_PORT} -> ${TARGET_HOST}:${TARGET_PORT}"
    else
      echo "not running."
    fi
    ;;
  *)
    echo "usage: $0 [start|stop|status]" >&2
    exit 2
    ;;
esac
