#!/usr/bin/env bash
# import-host-dir.sh — copy a directory from the host into the carbide-projects
# Docker volume under /srv/projects/<project_id>/, then trigger an FS rescan.
#
# Usage:
#   ./scripts/import-host-dir.sh /path/to/source 1
#   ./scripts/import-host-dir.sh /path/to/source        # defaults to project 1
#
# Notes:
#   * The target project must already exist in the DB (run quickstart.sh first
#     and log in once, or seed the DB).
#   * Existing files at the destination are overwritten.
#   * After copying, the script bounces the worker so FsLoader re-ingests.

set -euo pipefail

SRC="${1:-}"
PROJECT_ID="${2:-1}"
VOLUME="${CARBIDE_PROJECTS_VOLUME:-carbide-projects}"

if [[ -z "$SRC" || ! -d "$SRC" ]]; then
  echo "usage: $0 <source-dir> [project_id]"  >&2
  echo "  source-dir must be an existing host directory."  >&2
  exit 1
fi

command -v docker >/dev/null || { echo "docker not found" >&2; exit 1; }
docker volume inspect "$VOLUME" >/dev/null 2>&1 || {
  echo "volume '$VOLUME' not found — run quickstart.sh first." >&2; exit 1
}

SRC_ABS="$(cd "$SRC" && pwd)"
echo "[import] copying $SRC_ABS -> volume:$VOLUME at /srv/projects/$PROJECT_ID/"

# Run a one-shot alpine container with the source bind-mounted read-only and
# the projects volume mounted, then rsync the contents in.
docker run --rm \
  -v "$SRC_ABS:/src:ro" \
  -v "$VOLUME:/dst" \
  alpine:3 sh -c "
    apk add --no-cache rsync >/dev/null
    mkdir -p /dst/$PROJECT_ID
    rsync -a --delete-excluded \
      --exclude='.git/' --exclude='node_modules/' --exclude='tmp/' \
      --exclude='log/' --exclude='vendor/bundle/' \
      /src/ /dst/$PROJECT_ID/
    echo '[import] copy complete:'
    du -sh /dst/$PROJECT_ID
  "

echo "[import] bouncing worker so the new files get ingested"
docker compose restart carbide >/dev/null
echo "[import] done. tail worker logs with:  docker compose logs -f carbide | grep worker"
