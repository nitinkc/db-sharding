# Lab 6 — Solutions: Choosing a Shard Key

Shard ids below come from a real run — yours will differ numerically. What
matters is the *pattern*, not the ids.

## Task 1 — starting state

```sql
SELECT table_name, citus_table_type, distribution_column, shard_count, colocation_id
FROM citus_tables ORDER BY 1;
```

```
     table_name     | citus_table_type | distribution_column | shard_count | colocation_id
--------------------+------------------+---------------------+-------------+---------------
 sellers            | distributed      | seller_id           |           8 |             3
 sellers_by_country | distributed      | country             |           8 |             2
```

**Answer: (b)** — `sellers` distributed by `seller_id`, `sellers_by_country` by
`country`; `listings` and `favorites` still local.

## Task 2 — hash placement

```sql
SELECT id, get_shard_id_for_distribution_column('sellers', id) AS shardid
FROM generate_series(1,8) AS id;
```

```
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

- `SELECT count(DISTINCT country) FROM sellers_by_country;` → **5**
- `run_command_on_shards`: only **4 of 8** shards hold rows; the rest are empty.
- The fullest shard holds **6,000 of 10,000 rows = 60%** (all of 'US').
- A second shard holds 2,500 rows — two countries hashed to the same shard.

**Answer: (b)** — only a few shards hold rows, and one holds a large majority.

**Why:** the distribution column has only 5 distinct values, so at most 5
hash-buckets can ever receive rows; empty shards can never fill. Worse, the
*data itself* is skewed — 60% of sellers are 'US' — so even the shards that do
hold data are wildly unbalanced. Two properties decide spread: the column's
**cardinality** (how many buckets exist at all) and its **value distribution**
(how uniform the values are). `country` fails both; `seller_id` passes both.

## Task 4 — `listings` distributed by `listing_id`

```sql
SELECT create_distributed_table('listings','listing_id', shard_count:=8, colocate_with:='none');
EXPLAIN (COSTS OFF) SELECT * FROM listings WHERE seller_id = 1;
```

```
Custom Scan (Citus Adaptive)
  Task Count: 8
  Tasks Shown: One of 8
  -> Task
       Node: host=worker1 port=5432 dbname=bazaar
       -> Bitmap Heap Scan on listings_102024
```

**Answer:** the plan contains **8 shard queries — one per shard** (`Task
Count: 8`). `seller_id` is not the distribution column, so Citus can't tell
which shard holds seller 1's rows; it must ask *every* shard. This is a
**scatter-gather / fan-out** query. Seller 1's listings are also scattered
across shards instead of grouped together.

## Task 5 — `listings` redistributed by `seller_id`, co-located with `sellers`

```sql
SELECT undistribute_table('listings');
SELECT create_distributed_table('listings','seller_id', colocate_with:='sellers');
SELECT create_distributed_table('favorites','seller_id', colocate_with:='sellers');
EXPLAIN (COSTS OFF) SELECT * FROM listings WHERE seller_id = 1;
EXPLAIN (COSTS OFF) SELECT * FROM listings WHERE seller_id = 2;
```

```
Custom Scan (Citus Adaptive)
  Task Count: 1
  Tasks Shown: All
  -> Task
       Node: host=worker1 port=5432 dbname=bazaar
       -> ... on listings_10203x ... (seller_id = 1)
```

**Answer:** now the plan is **1 shard query on 1 node** (`Task Count: 1`) for
*both* sellers — including seller 2, whom we never queried before. Routing
doesn't depend on cached knowledge of specific rows: it's a pure computation —
`shard = hash(seller_id) mod 8` — so any seller id routes to exactly one shard.
This is a **router (single-shard) query**.

## Task 6 — co-location and joins

```sql
SELECT table_name::text, colocation_id FROM citus_tables
WHERE table_name::text IN ('sellers','listings','favorites') ORDER BY 1;
```

```
 favorites | 3
 listings  | 3
 sellers   | 3
```

```sql
EXPLAIN (COSTS OFF)
SELECT s.store_name, l.title
FROM sellers s JOIN listings l USING (seller_id)
WHERE s.seller_id = 1;
```

```
Custom Scan (Citus Adaptive)
  Task Count: 1
  -> Task
       Node: host=worker1 ...
       -> Nested Loop
            -> Index Scan on sellers_102016 s  (seller_id = 1)
            -> Bitmap Heap Scan on listings_102032 l (seller_id = 1)
```

**Answer:** all three tables share `colocation_id = 3` — same shard count, and
shard *N* of each table lives on the same worker. So seller 1's `sellers` row
and `listings` rows sit **side by side on worker1**, and the join runs **inside
a single task on the worker** — no data crosses the network, no coordinator
merge step. Same result for seller 3 (different shard, still one task).

Contrast with the plan when `listings` was local (or not co-located): the
coordinator had to fetch the seller row via a *subplan* and join locally —
more moving parts and network round-trips.

## Task 7 — shard key immutability

```sql
INSERT INTO sellers VALUES (20001,'shardkey_demo','Shard Key Demo');  -- ok
UPDATE sellers SET seller_id = 20002 WHERE seller_id = 20001;
-- ERROR:  modifying the partition value of rows is not allowed
```

Move instead:

```sql
BEGIN;
INSERT INTO sellers VALUES (20002,'shardkey_demo_moved','Shard Key Demo');
DELETE FROM sellers WHERE seller_id = 20001;
COMMIT;
```

Then:

```sql
SELECT get_shard_id_for_distribution_column('sellers',20001) AS old_shard,
       get_shard_id_for_distribution_column('sellers',20002) AS new_shard;
-- old_shard and new_shard are DIFFERENT shard ids, often on different workers

UPDATE sellers SET display_name='Shard Key Demo (moved)' WHERE seller_id=20002;
-- UPDATE 1  — works fine
```

**Answer:** changing the distribution column means the row must move to a
*different shard*, potentially on a *different machine*. Citus refuses to do
that inside a plain single-shard UPDATE. The workaround — delete + insert in
one transaction — makes the move explicit: delete targets the old shard, insert
targets the new one. Updating any *other* column stays in the same shard, so it
succeeds.

## Task 8 — range placement

Partitions and bounds:

```
 order_events_p2026_03_01 | FROM ('2026-03-01') TO ('2026-03-02')
 order_events_p2026_03_02 | FROM ('2026-03-02') TO ('2026-03-03')
 order_events_p2026_03_03 | FROM ('2026-03-03') TO (MAXVALUE)
```

Rows per partition:

```
 order_events_p2026_03_01 |  1000
 order_events_p2026_03_02 |  1000
 order_events_p2026_03_03 | 20000
```

- **All 20,000 new events landed in `p2026_03_03`** — the "current" partition.
  The two older partitions sit nearly idle for writes.
- The one-day query plan scans **exactly one partition**
  (`Seq Scan on order_events_p2026_03_01`) — partition pruning discards the
  rest without reading them.

**Interpretation:** range placement makes time-windowed *reads* extremely
efficient (read only the shards whose ranges overlap the window) but
concentrates all *writes* on the single shard holding "now" — the hot-shard
problem. Hash placement is the mirror image: perfectly balanced writes, but a
time-range read must touch every shard.

## Task 8.3 — physical children and pruning

`tableoid::regclass` identifies the actual child storing each returned row.
Expected counts from Task 8.1's seed are 1,000, 1,000, and 20,000; their sum is
22,000, equal to the parent query. No second copy of these rows is stored in the
partitioned parent.

The midnight probes identify the March 1, March 2, and March 3 partitions
respectively. March 2 midnight is excluded from the March 1 partition and
included in the March 2 partition.

These are local PostgreSQL children on the coordinator, described by
`pg_inherits`. They are not Citus shard placements. The `seller_id = 1` plan
retains all three children because that predicate supplies no bound on
`event_time`. The exact scan nodes depend on indexes and planner decisions;
the important observation is which child relations remain eligible.

A time predicate can prune children even when each retained child uses a
sequential scan. Conversely, a seller index can speed access inside each child
without allowing time-based pruning. Shard routing, partition pruning, and index
access are three distinct decisions.

## Task 8.4 — retention and future bounds

The candidate is `order_events_p2026_03_01`: its upper bound is March 2 and it
contains 1,000 rows. Detaching it would leave 21,000 rows visible through the
parent, while preserving the detached table as a standalone archive. Dropping
the child removes its data; neither operation needs a row-by-row delete when
the whole interval expires. Real operations still need backup, lock, and
retention planning. No detach or drop is performed in this lab.

The March 3 partition extends to `MAXVALUE`, so a new March 4 range would overlap
it and be rejected. Production daily rotation uses bounded future partitions,
or carefully reorganizes the catch-all and its rows before adding new ranges.

A native partitioned-parent primary key must include `event_time` so its
uniqueness can be enforced within partitions. `(event_time, event_id)` permits
the same `event_id` at different timestamps, so it does not establish global
uniqueness of `event_id` alone. If the table is also distributed by `seller_id`,
Citus's distribution-key requirements must be satisfied as well.

## Task 9 — strategy for weekly reports

**Answer:** **Range placement on `event_time`.** The weekly report reads one
contiguous time window, so range shards let the planner touch only the
partitions covering that week instead of fanning out to every shard.

**Trade-off:** every new insert lands in the "current" partition, so writes
concentrate on one hot shard while older shards idle — the classic
range-sharding write hotspot. (Mitigations in real systems: rotate and retire
old partitions, sub-shard the hot range, or accept it when read latency matters
more than write balance.)
