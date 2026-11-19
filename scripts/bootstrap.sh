#!/usr/bin/env bash
# Bring up the fleet Citus cluster and register the workers. Deliberately
# shards nothing: every table starts as a local table on the coordinator, and
# the labs distribute them one by one.
set -euo pipefail
cd "$(dirname "$0")/.."

echo ">> Starting containers"
docker compose up -d

echo ">> Waiting for the coordinator to accept connections"
# -h localhost forces a TCP check: the entrypoint's temporary init server is
# unix-socket-only, so a plain pg_isready would report ready before the
# docker-entrypoint-initdb.d scripts (CREATE EXTENSION citus) have finished.
until docker exec fleet-coordinator pg_isready -h localhost -U postgres -d fleet >/dev/null 2>&1; do
  sleep 1
done
until docker exec fleet-worker1 pg_isready -h localhost -U postgres -d fleet >/dev/null 2>&1 &&
      docker exec fleet-worker2 pg_isready -h localhost -U postgres -d fleet >/dev/null 2>&1 &&
      docker exec fleet-worker3 pg_isready -h localhost -U postgres -d fleet >/dev/null 2>&1; do
  sleep 1
done

PSQL="docker exec fleet-coordinator psql -U postgres -d fleet -v ON_ERROR_STOP=1 -qAt"

echo ">> Registering workers (idempotent)"
for w in worker1 worker2 worker3; do
  if ! $PSQL -c "SELECT 1 FROM citus_get_active_worker_nodes() WHERE node_name = '$w'" | grep -q 1; then
    $PSQL -c "SELECT citus_add_node('$w', 5432);"
  fi
done

echo
echo ">> Cluster is ready. Connect with:"
echo "   psql -h localhost -p 5432 -U postgres -d fleet"
echo "   (or: docker exec -it fleet-coordinator psql -U postgres -d fleet)"
echo
$PSQL -c "SELECT node_name, node_port FROM citus_get_active_worker_nodes() ORDER BY 1;"
