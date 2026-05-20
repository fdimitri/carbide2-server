#!/usr/bin/env bash
# dev.sh — start all three Carbide2 dev processes
#CARBIDE_USE_DOCKER=1
set -e
ROOT="$(cd "$(dirname "$0")" && pwd)"

: "${WORKER_JWT_SECRET:=password}"
export WORKER_JWT_SECRET

echo "[carbide2] starting rails..."
bundle exec rails server -p 3000 -b 0.0.0.0 &
RAILS_PID=$!

echo "[carbide2] starting worker..."
bundle exec ruby worker/worker.rb >> /tmp/carbide2-worker.log 2>&1 &
WORKER_PID=$!

echo "[carbide2] starting vite client..."
cd "$ROOT/clients/carbide2-client" && npm run dev &
VITE_PID=$!

echo "[carbide2] pids: rails=$RAILS_PID worker=$WORKER_PID vite=$VITE_PID"
echo "[carbide2] ctrl-c to stop all"

trap "kill $RAILS_PID $WORKER_PID $VITE_PID 2>/dev/null" EXIT INT TERM
wait
