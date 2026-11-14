# Lab 3 — Solutions

## Step 1 — before

```sql
SELECT count(*) FROM sellers;
-- 10000
```

## Step 2 — distribute

```sql
SELECT create_distributed_table('sellers', 'seller_id', shard_count := 8);
```

```
NOTICE:  Copying data from local table...
NOTICE:  copying the data has completed
DETAIL:  The local data in the table is no longer visible, but is still on disk.
```

Citus creates 8 shards on the workers and streams the existing 10,000 rows into
them. The leftover local copy can be dropped with
`SELECT truncate_local_data_after_distributing_table('public.sellers')`
(optional — the labs don't require it).

## Step 3 — verify

```sql
SELECT table_name, citus_table_type, distribution_column, shard_count
FROM citus_tables WHERE table_name = 'sellers'::regclass;
```

```
 table_name | citus_table_type | distribution_column | shard_count
------------+------------------+---------------------+-------------
 sellers    | distributed      | seller_id           |           8
```

```sql
SELECT count(*) FROM sellers;   -- 10000 — unchanged
SELECT * FROM sellers WHERE seller_id = 1;   -- Leather Lane — readable
```

All four checkpoint conditions hold.
