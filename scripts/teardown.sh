#!/usr/bin/env bash
# Stop the fleet Citus cluster. By default this also removes the data volumes
# so the next bootstrap starts clean; pass --keep-data to keep them.
set -euo pipefail
cd "$(dirname "$0")/.."

if [[ "${1:-}" == "--keep-data" ]]; then
  echo ">> Stopping containers (volumes kept)"
  docker compose down
else
  echo ">> Stopping containers and removing volumes"
  docker compose down -v
fi
