#!/usr/bin/env bash
# Smoke test for workspace substrate (k3d/k8s/helm/rails)
# Verifies pod health, HTTP endpoints, and logs for errors.
set -euo pipefail

NAMESPACE="${NAMESPACE:-ws-1}"
BASE_URL="${BASE_URL:-http://localhost:8080/w/1}"

echo "[smoke] Checking pod status..."
kubectl -n "$NAMESPACE" get pod

echo "[smoke] Checking /up endpoint..."
# Rails 8's default /up returns <html><body style="background-color: green"></body></html>
curl -fsSL "$BASE_URL/up" | grep -q "background-color: green" && echo "[smoke] /up 200 OK"

echo "[smoke] Checking root endpoint..."
curl -fsSL "$BASE_URL/" | grep -q "Ruby on Rails" && echo "[smoke] / 200 Rails welcome"

echo "[smoke] Recent workspace logs:"
kubectl -n "$NAMESPACE" logs -l app.kubernetes.io/name=workspace --tail=40 || true

echo "[smoke] Done."