#!/usr/bin/env bash
# Run the Rails minitest suite inside the workspace pod.
#
# Usage:
#   scripts/test-rails.sh            # run full suite for ws-1
#   scripts/test-rails.sh ws-2 …     # run for a different namespace
#
# Requires:
#   - The workspace pod (deploy/ws-N) is running.
#   - The CNPG cluster is up and the carbide role has CREATEDB+SUPERUSER
#     (set automatically by deploy/cnpg-cluster.yaml postInitApplicationSQL).
set -euo pipefail

NS="${1:-ws-1}"
shift || true

POD="$(kubectl -n "$NS" get pod -l app.kubernetes.io/name=workspace \
        -o jsonpath='{.items[0].metadata.name}')"
[[ -n "$POD" ]] || { echo "No workspace pod in namespace $NS" >&2; exit 1; }

echo "Running Rails tests in $NS/$POD …"
kubectl -n "$NS" exec "$POD" -c workspace -- \
  sh -c "cd /app && RAILS_ENV=test bundle exec rails db:drop db:create db:migrate && \
         RAILS_ENV=test bundle exec rails test $*"
