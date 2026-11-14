#!/usr/bin/env bash
# Bring up the bazaar Citus cluster, register the workers, and distribute the
# one table the course expects to be pre-distributed (sellers_by_country).
set -euo pipefail
cd "$(dirname "$0")/.."

echo ">> Starting containers"
docker compose up -d

echo ">> Waiting for the coordinator to accept connections"
until docker exec bazaar-coordinator pg_isready -U postgres -d bazaar >/dev/null 2>&1; do
  sleep 1
done
until docker exec bazaar-worker1 pg_isready -U postgres -d bazaar >/dev/null 2>&1 &&
      docker exec bazaar-worker2 pg_isready -U postgres -d bazaar >/dev/null 2>&1; do
  sleep 1
done

PSQL="docker exec bazaar-coordinator psql -U postgres -d bazaar -v ON_ERROR_STOP=1 -qAt"

echo ">> Registering workers (idempotent)"
for w in worker1 worker2; do
  if ! $PSQL -c "SELECT 1 FROM citus_get_active_worker_nodes() WHERE node_name = '$w'" | grep -q 1; then
    $PSQL -c "SELECT citus_add_node('$w', 5432);"
  fi
done

echo ">> Distributing sellers_by_country by country (idempotent)"
if ! $PSQL -c "SELECT 1 FROM citus_tables WHERE table_name = 'sellers_by_country'::regclass" | grep -q 1; then
  $PSQL -c "SELECT create_distributed_table('sellers_by_country', 'country', shard_count := 8);"
fi

echo
echo ">> Cluster is ready. Connect with:"
echo "   psql -h localhost -p 5432 -U postgres -d bazaar"
echo "   (or: docker exec -it bazaar-coordinator psql -U postgres -d bazaar)"
echo
$PSQL -c "SELECT node_name, node_port FROM citus_get_active_worker_nodes() ORDER BY 1;"
