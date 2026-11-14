# Lab 2 — Solutions

## Evidence

**1. `citus_tables`:**

```sql
SELECT table_name, citus_table_type, distribution_column, shard_count
FROM citus_tables WHERE table_name = 'sellers'::regclass;
-- 0 rows
```

**2. `citus_shards`:**

```sql
SELECT * FROM citus_shards WHERE table_name = 'sellers'::regclass;
-- 0 rows
```

**3. Row count through the coordinator:**

```sql
SELECT count(*) FROM sellers;
-- 10000
```

## Answer

`sellers` is a **local table**. Citus does not manage it: it appears in neither
`citus_tables` nor `citus_shards`, yet all 10,000 rows are readable through the
coordinator — because the whole table physically lives on the coordinator as an
ordinary PostgreSQL table. No worker holds any part of it.

(If you also looked at `sellers_by_country`, it *does* appear in
`citus_tables` as `distributed` on `country` — the bootstrap script
pre-distributed that one.)
