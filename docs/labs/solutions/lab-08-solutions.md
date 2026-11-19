# Lab 8 — Solutions: Distributed Time-Series & Geofencing

Shard ids below come from a real run — yours will differ numerically.

## Task 1 — distribute the partitioned parent

```sql
SELECT create_distributed_table('vehicle_telematics', 'fleet_id', colocate_with := 'fleets');

SELECT table_name, count(*) AS shards
FROM citus_shards
WHERE table_name::text LIKE 'vehicle_telematics%'
GROUP BY table_name ORDER BY table_name;
```

```text
           table_name           | shards
--------------------------------+--------
 vehicle_telematics             |      8
 vehicle_telematics_p2026_11_14 |      8
 vehicle_telematics_p2026_11_15 |      8
 vehicle_telematics_p2026_11_16 |      8
```

**Answers:**

1. **32 shard rows** — Citus distributes the parent's routing metadata (8
   shards) *and* creates 8 real shard tables per partition on the workers. A
   partitioned+distributed table costs `partitions × shard_count` objects;
   that's the multiplier Module 04 warns about.
2. `SELECT count(*) FROM vehicle_telematics;` → **22,000** — unchanged; all
   rows were re-homed into the per-partition shards during distribution.
3. A PK must include **both** `fleet_id` (Citus distribution column) **and**
   `recorded_at` (Postgres partition key) — e.g.
   `(fleet_id, recorded_at, ping_id)`.

## Task 2 — two-layer pruning

```sql
EXPLAIN (COSTS OFF)
SELECT vehicle_id, recorded_at, speed_kph
FROM vehicle_telematics
WHERE fleet_id = 101
  AND recorded_at >= '2026-11-14' AND recorded_at < '2026-11-15';
```

```text
Custom Scan (Citus Adaptive)
  Task Count: 1
  Tasks Shown: All
  -> Task
       Node: host=worker2 port=5432 dbname=fleet
       -> Seq Scan on vehicle_telematics_p2026_11_14_102059
            Filter: (recorded_at >= ...) AND (recorded_at < ...) AND (fleet_id = 101)
```

`Task Count: 1` (shard pruning on `fleet_id`) **and** only the Nov 14
partition's shard table appears (partition pruning on `recorded_at`).

Widening the window to `< '2026-11-17'` keeps `Task Count: 1` — all of
fleet 101's pings live in one shard regardless of time — but the task's `Append`
now lists **three** partition scans (`_p2026_11_14_`, `_p2026_11_15_`,
`_p2026_11_16_`). Two independent prunings: the shard layer routes, the
partition layer filters.

## Task 3 — spatial index inside the shard

```sql
CREATE INDEX idx_telematics_geo
    ON vehicle_telematics USING GIST ((location::geography));
```

```text
Custom Scan (Citus Adaptive)
  Task Count: 1
  -> Task
       Node: host=worker2 ...
       -> Index Scan using vehicle_telematics_p2026_11_16_location_idx_102075
            on vehicle_telematics_p2026_11_16_102075
            Index Cond: (location)::geography && _st_expand('...'::geography, '2000')
            Filter: ... AND st_dwithin((location)::geography, '...'::geography, '2000', true)
```

**Answer:** the coordinator picked fleet 1's single shard; inside it, only the
Nov 16 partition survived pruning; inside that, the **GiST index** (created on
the parent, propagated to every shard) does bounding-box pre-filtering with
`&&`/`_st_expand`, then `st_dwithin` verifies exact distance in metres. The
query never touched other fleets' shards, the older partitions, or the ~20k
points outside the 2 km box. Three different "don't read this" mechanisms in
one plan.

## Task 4 — geofencing with a reference table

```sql
SELECT create_reference_table('service_zones');
```

The join plan is still `Task Count: 1`, and inside the task:

```text
-> Nested Loop
     Join Filter: st_contains(z.boundary, t.location)
     -> Seq Scan on vehicle_telematics_p2026_11_16_102075 t
          Filter: ... AND (fleet_id = 1)
     -> Seq Scan on service_zones_102080 z
```

`service_zones_102080` is the **local copy on that worker** — the join runs
entirely inside the shard task; no rows cross the network.

The query result: essentially all Nov-16 pings resolve to **Newark Airport**
(the seed clustered them inside that geofence).

**Answers:**

1. `service_zones_102080` lives on the same worker as the ping shard — a full
   copy, so `ST_Contains` is a local join.
2. A reference table wins because `service_zones` is **tiny and
   slowly-changing** (geofences are edited rarely, read constantly).
   Distributing it would scatter 5 polygons across shards and force every
   geofence join to fetch from another node. The assumption breaks if the
   table grows large or write-hot — reference copies multiply write cost.
3. `shard_count` is not 8 because a reference table isn't hash-sliced — it's
   replicated *in full* on every worker (Citus still tracks it as shard
   objects, one per placement).

## Task 5 — retention across the cluster

```sql
DROP TABLE vehicle_telematics_p2026_11_14;
```

```text
           table_name           | count
--------------------------------+-------
 vehicle_telematics             |     8
 vehicle_telematics_p2026_11_15 |     8
 vehicle_telematics_p2026_11_16 |     8
```

`SELECT count(*) FROM vehicle_telematics;` → **21,000**.

**Answers:**

1. Citus intercepts DDL on distributed objects and **propagates the `DROP
   TABLE` to every shard placement** on worker1, worker2, and worker3 — one coordinator
   statement, cluster-wide effect.
2. `DELETE` would touch ~1,000 tuples per shard, generate WAL and dead tuples,
   and leave `VACUUM` debt on every worker; `DROP` is a metadata + file
   unlink — instant regardless of row count.
3. `ALTER TABLE vehicle_telematics DETACH PARTITION ...` would have kept the
   partition as a standalone (still-distributed) archive table — the pings
   would remain queryable under their own name, just no longer through the
   parent. `DROP` removed the data outright.

## Stretch — attach tomorrow's partition

Attaching a bounded partition to a distributed parent creates its worker
shards automatically — `citus_shards` lists
`vehicle_telematics_p2026_11_17` with 8 shards immediately after the `ATTACH`.

Because `p2026_11_16` runs to `MAXVALUE`, a bounded Nov 17 partition can't
attach while it exists. Production rotation would: create the bounded
partition, detach the `MAXVALUE` catch-all (renaming it or keeping it as the
next bounded range), attach the new bounded range, and optionally re-attach a
fresh empty catch-all — each step propagating to the workers.
