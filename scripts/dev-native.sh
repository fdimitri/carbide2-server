#!/usr/bin/env bash
# dev.sh — start all three Carbide2 dev processes
export CARBIDE_USE_DOCKER=1
export CARBIDE_SHELL_IMAGE=carbide2-shell

set -e
# ROOT here is the scripts/ dir; SERVER is the carbide2-server checkout.
# CARBIDE2_CLIENT defaults to a sibling carbide2-client checkout, matching
# the layout the carbide2 meta-repo lays down. Override if your checkouts
# live elsewhere.
ROOT="$(cd "$(dirname "$0")" && pwd)"
SERVER="$(cd "$ROOT/.." && pwd)"
: "${CARBIDE2_CLIENT:=$SERVER/../carbide2-client}"
export CARBIDE2_CLIENT

: "${WORKER_JWT_SECRET:=password}"
export WORKER_JWT_SECRET

echo "[carbide2] starting rails..."
bundle exec rails server -p 3000 -b 0.0.0.0 &
RAILS_PID=$!

echo "[carbide2] starting worker..."
bundle exec ruby worker/worker.rb >> /tmp/carbide2-worker.log 2>&1 &
WORKER_PID=$!

echo "[carbide2] starting vite client (from $CARBIDE2_CLIENT)..."
cd "$CARBIDE2_CLIENT" && npm run dev &
VITE_PID=$!

echo "[carbide2] pids: rails=$RAILS_PID worker=$WORKER_PID vite=$VITE_PID"
echo "[carbide2] ctrl-c to stop all"

trap "kill $RAILS_PID $WORKER_PID $VITE_PID 2>/dev/null" EXIT INT TERM
wait
