# Lab 5 — Solutions

## Step 1 — rows per shard

```sql
SELECT * FROM run_command_on_shards('sellers', 'SELECT count(*) FROM %s')
ORDER BY shardid;
```

Observed (your numbers may differ slightly — hashing decides):

```
 shardid | success | result
---------+---------+--------
  102016 | t       | 1217
  102017 | t       | 1240
  102018 | t       | 1279
  102019 | t       | 1260
  102020 | t       | 1274
  102021 | t       | 1285
  102022 | t       | 1218
  102023 | t       | 1227
```

Sum: **10,000** — exactly the count through the coordinator. No row lost, none
duplicated.

## Step 2 — where seller 1 lives

```sql
SELECT get_shard_id_for_distribution_column('sellers', 1);
-- e.g. 102016  (shard ids differ between cluster builds — that's fine)

SELECT shardid, nodename FROM citus_shards
WHERE table_name = 'sellers'::regclass
  AND shardid = get_shard_id_for_distribution_column('sellers', 1);
```

Seller 1 lives in exactly **one** shard, on exactly **one** worker.

## Interpretation

- The coordinator's view of a distributed table is a **logical union** of the
  shards; what you query is what the shards collectively hold.
- Hash routing is a pure function of the distribution-column value: the same
  `seller_id` always maps to the same shard id, so a value can never be in two
  shards at once.
