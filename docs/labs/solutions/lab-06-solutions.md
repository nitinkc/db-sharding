# Lab 6 — Solutions: Choosing a Shard Key

Shard ids below come from a real run — yours will differ numerically. What
matters is the *pattern*, not the ids.

## Task 1 — starting state

```sql
SELECT table_name, citus_table_type, distribution_column, shard_count, colocation_id
FROM citus_tables ORDER BY 1;
```

```text
     table_name     | citus_table_type | distribution_column | shard_count | colocation_id
--------------------+------------------+---------------------+-------------+---------------
 fleets             | distributed      | fleet_id            |           8 |             3
```

**Answer: (b)** — `fleets` distributed by `fleet_id`; `vehicles`, `trips`,
`vehicles_by_region`, and `service_zones` still local. The cluster starts with
*no* distributed tables — `fleets` is only distributed because you did it in
Lab 3.

## Task 2 — hash placement

```sql
SELECT id, get_shard_id_for_distribution_column('fleets', id) AS shardid
FROM generate_series(1,8) AS id;
```

```text
 id | shardid      -- example run
----+---------
  1 | 102016
  2 | 102022
  3 | 102019
  4 | 102018
  5 | 102017
  6 | 102021
  7 | 102018
  8 | 102016
```

**Observation:** consecutive ids scatter to *different, non-adjacent* shards —
the mapping looks random. But re-running gives **identical** results: hashing
is deterministic, not random. Consecutive keys never share a shard by accident
of ordering, which is why hash placement spreads monotonic keys evenly.

## Task 3 — cardinality and spread

```sql
SELECT create_distributed_table('vehicles_by_region', 'region', shard_count := 8);
```

- `SELECT count(DISTINCT region) FROM vehicles_by_region;` → **5**
- `run_command_on_shards`: only **4 of 8** shards hold rows; the rest are empty.
- The fullest shard holds **6,000 of 10,000 rows = 60%** (all of 'NA').
- A second shard holds 2,500 rows — two regions hashed to the same shard.

**Answer: (b)** — only a few shards hold rows, and one holds a large majority.

**Why:** the distribution column has only 5 distinct values, so at most 5
hash-buckets can ever receive rows; empty shards can never fill. Worse, the
*data itself* is skewed — 60% of vehicles are 'NA' — so even the shards that do
hold data are wildly unbalanced. Two properties decide spread: the column's
**cardinality** (how many buckets exist at all) and its **value distribution**
(how uniform the values are). `region` fails both; `fleet_id` passes both.

## Task 4 — `vehicles` distributed by `vehicle_id`

```sql
SELECT create_distributed_table('vehicles','vehicle_id', shard_count:=8, colocate_with:='none');
EXPLAIN (COSTS OFF) SELECT * FROM vehicles WHERE fleet_id = 1;
```

```text
Custom Scan (Citus Adaptive)
  Task Count: 8
  Tasks Shown: One of 8
  -> Task
       Node: host=worker1 port=5432 dbname=fleet
       -> Bitmap Heap Scan on vehicles_102024
```

**Answer:** the plan contains **8 shard queries — one per shard** (`Task
Count: 8`). `fleet_id` is not the distribution column, so Citus can't tell
which shard holds fleet 1's rows; it must ask *every* shard. This is a
**scatter-gather / fan-out** query. Fleet 1's vehicles are also scattered
across shards instead of grouped together.

## Task 5 — `vehicles` redistributed by `fleet_id`, co-located with `fleets`

```sql
SELECT undistribute_table('vehicles');
SELECT create_distributed_table('vehicles','fleet_id', colocate_with:='fleets');
SELECT create_distributed_table('trips','fleet_id', colocate_with:='fleets');
EXPLAIN (COSTS OFF) SELECT * FROM vehicles WHERE fleet_id = 1;
EXPLAIN (COSTS OFF) SELECT * FROM vehicles WHERE fleet_id = 2;
```

```text
Custom Scan (Citus Adaptive)
  Task Count: 1
  Tasks Shown: All
  -> Task
       Node: host=worker1 port=5432 dbname=fleet
       -> ... on vehicles_10203x ... (fleet_id = 1)
```

**Answer:** now the plan is **1 shard query on 1 node** (`Task Count: 1`) for
*both* fleets — including fleet 2, whom we never queried before. Routing
doesn't depend on cached knowledge of specific rows: it's a pure computation —
`shard = hash(fleet_id) mod 8` — so any fleet id routes to exactly one shard.
This is a **router (single-shard) query**.

## Task 6 — co-location and joins

```sql
SELECT table_name::text, colocation_id FROM citus_tables
WHERE table_name::text IN ('fleets','vehicles','trips') ORDER BY 1;
```

```text
 fleets   | 3
 trips    | 3
 vehicles | 3
```

```sql
EXPLAIN (COSTS OFF)
SELECT f.fleet_name, v.license_plate
FROM fleets f JOIN vehicles v USING (fleet_id)
WHERE f.fleet_id = 1;
```

```text
Custom Scan (Citus Adaptive)
  Task Count: 1
  -> Task
       Node: host=worker1 ...
       -> Nested Loop
            -> Index Scan on fleets_102016 f  (fleet_id = 1)
            -> Bitmap Heap Scan on vehicles_102032 v (fleet_id = 1)
```

**Answer:** all three tables share `colocation_id = 3` — same shard count, and
shard *N* of each table lives on the same worker. So fleet 1's `fleets` row
and `vehicles` rows sit **side by side on worker1**, and the join runs **inside
a single task on the worker** — no data crosses the network, no coordinator
merge step. Same result for fleet 3 (different shard, still one task).

Contrast with the plan when `vehicles` was local (or not co-located): the
coordinator had to fetch the fleet row via a *subplan* and join locally —
more moving parts and network round-trips.

## Task 7 — shard key immutability

```sql
INSERT INTO fleets VALUES (20001,'shardkey_demo','Shard Key Demo');  -- ok
UPDATE fleets SET fleet_id = 20002 WHERE fleet_id = 20001;
-- ERROR:  modifying the partition value of rows is not allowed
```

Move instead:

```sql
BEGIN;
INSERT INTO fleets VALUES (20002,'shardkey_demo_moved','Shard Key Demo');
DELETE FROM fleets WHERE fleet_id = 20001;
COMMIT;
```

Then:

```sql
SELECT get_shard_id_for_distribution_column('fleets',20001) AS old_shard,
       get_shard_id_for_distribution_column('fleets',20002) AS new_shard;
-- old_shard and new_shard are DIFFERENT shard ids, often on different workers

UPDATE fleets SET home_city='Shard Key Demo (moved)' WHERE fleet_id=20002;
-- UPDATE 1  — works fine
```

**Answer:** changing the distribution column means the row must move to a
*different shard*, potentially on a *different machine*. Citus refuses to do
that inside a plain single-shard UPDATE. The workaround — delete + insert in
one transaction — makes the move explicit: delete targets the old shard, insert
targets the new one. Updating any *other* column stays in the same shard, so it
succeeds.
