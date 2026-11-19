# Lab 4 — Solutions

## Step 1 — shard count

```sql
SELECT count(*) FROM citus_shards WHERE table_name = 'fleets'::regclass;
-- 8
```

## Step 2 — placements per worker

```sql
SELECT nodename, count(*) AS placements
FROM citus_shards WHERE table_name = 'fleets'::regclass
GROUP BY nodename ORDER BY nodename;
```

```text
 nodename | placements
----------+------------
 worker1  |          3
 worker2  |          3
 worker3  |          2
```

## Step 3 — shards placed more than once

```sql
SELECT shardid, count(*) FROM citus_shards
WHERE table_name = 'fleets'::regclass
GROUP BY shardid HAVING count(*) > 1;
-- 0 rows
```

## Answer

**(b)** — 8 shards, split roughly evenly across the workers (3, 3, and 2 — the
exact split is up to the placement algorithm), each shard placed exactly
once.

The replication factor is 1, so each shard has a single placement. Had we set
`citus.shard_replication_factor = 2`, every shard would appear twice — once per
worker — and the Step-3 query would return 8 rows.
