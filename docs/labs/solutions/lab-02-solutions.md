# Lab 2 — Solutions

## Evidence

**1. `citus_tables`:**

```sql
SELECT table_name, citus_table_type, distribution_column, shard_count
FROM citus_tables WHERE table_name = 'fleets'::regclass;
-- 0 rows
```

**2. `citus_shards`:**

```sql
SELECT * FROM citus_shards WHERE table_name = 'fleets'::regclass;
-- 0 rows
```

**3. Row count through the coordinator:**

```sql
SELECT count(*) FROM fleets;
-- 10000
```

## Answer

`fleets` is a **local table**. Citus does not manage it: it appears in neither
`citus_tables` nor `citus_shards`, yet all 10,000 rows are readable through the
coordinator — because the whole table physically lives on the coordinator as an
ordinary PostgreSQL table. No worker holds any part of it.

(In fact, at this point `citus_tables` returns **zero rows** for every table —
the bootstrap script distributes nothing. Every table you meet in Labs 1–2 is
local; you distribute the first one yourself in Lab 3.)
