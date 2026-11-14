# Lab 1 — Solutions

## Task 1.1 — Citus version

```sql
SELECT extname, extversion FROM pg_extension WHERE extname = 'citus';
-- or simply: \dx
```

```
 extname | extversion
---------+------------
 citus   | 12.1-1
```

**Answer:** Citus 12.1-1 is installed. (Your minor version may differ if the
Docker image tag in `docker-compose.yml` has been updated — that is expected.)

## Task 1.2 — Active workers

```sql
SELECT node_name, node_port FROM citus_get_active_worker_nodes() ORDER BY 1;
```

```
 node_name | node_port
-----------+-----------
 worker1   |      5432
 worker2   |      5432
```

**Answer:** **2** active workers. You can also inspect `pg_dist_node` for the
full node registry (includes the coordinator once it's registered, plus
inactive nodes if any).
