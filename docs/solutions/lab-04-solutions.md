# Lab 4 — Solutions

## Step 1 — shard count

```sql
SELECT count(*) FROM citus_shards WHERE table_name = 'sellers'::regclass;
-- 8
```

## Step 2 — placements per worker

```sql
SELECT nodename, count(*) AS placements
FROM citus_shards WHERE table_name = 'sellers'::regclass
GROUP BY nodename ORDER BY nodename;
```

```
 nodename | placements
----------+------------
 worker1  |          4
 worker2  |          4
```

## Step 3 — shards placed more than once

```sql
SELECT shardid, count(*) FROM citus_shards
WHERE table_name = 'sellers'::regclass
GROUP BY shardid HAVING count(*) > 1;
-- 0 rows
```

## Answer

**(b)** — 8 shards, split roughly evenly across the workers (4 and 4), each
shard placed exactly once.

The replication factor is 1, so each shard has a single placement. Had we set
`citus.shard_replication_factor = 2`, every shard would appear twice — once per
worker — and the Step-3 query would return 8 rows.
