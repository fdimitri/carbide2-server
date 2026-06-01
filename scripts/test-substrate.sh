#!/usr/bin/env bash
# Run all substrate test layers in order against a deployed workspace.
#
# Layers:
#   1. Bash smoke (HTTP + pod health)
#   2. Helm test  (chart-defined pod tests)
#   3. Rails minitest (inside the workspace pod)
#   4. Playwright E2E (substrate spec)
#
# Env overrides:
#   NAMESPACE     (default ws-1)
#   BASE_URL      (default http://localhost:8080/w/1)   bash + playwright
#   CARBIDE_WS_URL same as BASE_URL but for playwright
set -euo pipefail

NAMESPACE="${NAMESPACE:-ws-1}"
BASE_URL="${BASE_URL:-http://localhost:8080/w/1}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

echo "==> [1/4] bash smoke"
NAMESPACE="$NAMESPACE" BASE_URL="$BASE_URL" "$ROOT/scripts/smoke-test.sh"

echo "==> [2/4] helm test"
helm test "$NAMESPACE" -n "$NAMESPACE"

echo "==> [3/4] rails minitest"
"$ROOT/scripts/test-rails.sh" "$NAMESPACE"

echo "==> [4/4] playwright e2e"
cd "$ROOT/clients/carbide2-client"

# Seed a known user so the login spec has something to authenticate against.
# Idempotent: find_or_create_by! never raises on re-runs.
E2E_EMAIL="${CARBIDE_E2E_EMAIL:-e2e@example.com}"
E2E_PASSWORD="${CARBIDE_E2E_PASSWORD:-password123}"
kubectl -n "$NAMESPACE" exec deploy/ws-1 -c workspace -- \
  bundle exec rails runner \
  "User.find_or_create_by!(email: '${E2E_EMAIL}') { |u| u.password = '${E2E_PASSWORD}' }" \
  >/dev/null

CARBIDE_WS_URL="${CARBIDE_WS_URL:-$BASE_URL}" \
CARBIDE_E2E_EMAIL="$E2E_EMAIL" \
CARBIDE_E2E_PASSWORD="$E2E_PASSWORD" \
  npx playwright test tests/e2e/workspace-smoke.spec.js tests/e2e/workspace-login.spec.js --reporter=list

echo "==> All substrate tests passed."
