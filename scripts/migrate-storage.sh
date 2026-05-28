#!/usr/bin/env bash
# Export or import the carbide-projects named volume as a tarball, so the
# whole container group is portable between hosts without coupling project
# files to any specific host path.
#
# Usage:
#   scripts/migrate-storage.sh export <output.tar.gz>
#   scripts/migrate-storage.sh import <input.tar.gz>
#
# The volume name is taken from CARBIDE_PROJECT_VOLUME (default
# "carbide2-server_carbide-projects" — the name docker compose creates from
# the project directory plus the volume key in docker-compose.yml).

set -euo pipefail

VOLUME="${CARBIDE_PROJECT_VOLUME:-carbide2-server_carbide-projects}"
ACTION="${1:-}"
FILE="${2:-}"

usage() {
  echo "Usage: $0 export <output.tar.gz>" >&2
  echo "       $0 import <input.tar.gz>"  >&2
  exit 1
}

if [[ -z "$ACTION" || -z "$FILE" ]]; then
  usage
fi

case "$ACTION" in
  export)
    abs="$(cd "$(dirname "$FILE")" && pwd)/$(basename "$FILE")"
    echo "Exporting volume $VOLUME -> $abs"
    docker run --rm \
      -v "$VOLUME":/data \
      -v "$(dirname "$abs")":/backup \
      alpine \
      tar czf "/backup/$(basename "$abs")" -C /data .
    echo "Done."
    ;;
  import)
    if [[ ! -f "$FILE" ]]; then
      echo "Input file not found: $FILE" >&2
      exit 1
    fi
    abs="$(cd "$(dirname "$FILE")" && pwd)/$(basename "$FILE")"
    echo "Importing $abs -> volume $VOLUME"
    docker volume create "$VOLUME" >/dev/null
    docker run --rm \
      -v "$VOLUME":/data \
      -v "$(dirname "$abs")":/backup \
      alpine \
      sh -c "tar xzf /backup/$(basename "$abs") -C /data"
    echo "Done."
    ;;
  *)
    usage
    ;;
esac
