# Lab 1 — Solutions

```bash
psql -h localhost -p 5432 -U postgres -d fleet 
```

## Task 1.1 — Installed extensions


```sql
SELECT extname, extversion FROM pg_extension
WHERE extname IN ('citus', 'postgis') ORDER BY 1;
-- or simply: \dx
```

```text
 extname  | extversion
----------+------------
 citus    | 13.4-1
 postgis  | 3.7.0
```

**Answer:** Citus 13.4-1 and PostGIS 3.7 are installed. PostGIS is the
geospatial engine the geofencing labs use for `ST_DWithin` / `ST_Contains`.
(Your minor versions may differ if the image tag in `docker-compose.yml` or
`db/Dockerfile` has been updated — that is expected.)

## Task 1.2 — Active workers

```sql
SELECT node_name, node_port FROM citus_get_active_worker_nodes() ORDER BY 1;
```

```text
 node_name | node_port
-----------+-----------
 worker1   |      5432
 worker2   |      5432
 worker3   |      5432
```

**Answer:** **3** active workers. You can also inspect `pg_dist_node` for the
full node registry (includes the coordinator once it's registered, plus
inactive nodes if any).
