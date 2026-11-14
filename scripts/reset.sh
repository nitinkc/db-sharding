#!/usr/bin/env bash
# Tear the cluster down completely and rebuild it from scratch.
set -euo pipefail
cd "$(dirname "$0")/.."

echo ">> Removing containers and volumes"
docker compose down -v

exec "$(dirname "$0")/bootstrap.sh"
