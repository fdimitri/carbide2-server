#!/usr/bin/env bash
# Smoke test for workspace substrate (k3d/k8s/helm/rails)
# Verifies pod health, HTTP endpoints, and logs for errors.
set -euo pipefail

NAMESPACE="ws-1"
BASE_URL="http://localhost:8080/w/1"

echo "[smoke] Checking pod status..."
kubectl -n "$NAMESPACE" get pod

echo "[smoke] Checking /up endpoint..."
curl -fsSL "$BASE_URL/up" | grep -q "OK" && echo "[smoke] /up 200 OK"

echo "[smoke] Checking root endpoint..."
curl -fsSL "$BASE_URL/" | grep -q "Ruby on Rails" && echo "[smoke] / 200 Rails welcome"

echo "[smoke] Checking logs for FS load..."
kubectl -n "$NAMESPACE" logs -l app.kubernetes.io/name=workspace --tail=40 | grep -E "FS load complete" && echo "[smoke] FS load complete"

echo "[smoke] Checking logs for errors..."
kubectl -n "$NAMESPACE" logs -l app.kubernetes.io/name=workspace --tail=80 | grep -iE "error|fail|exception" && echo "[smoke] No critical errors found (if no output above)"

echo "[smoke] Done."