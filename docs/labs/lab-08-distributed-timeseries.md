# Lab 8 — Distributed Time-Series & Geofencing

**Module reference:** [Module 03](../modules/03-citus-architecture.md) ·
[Module 05](../modules/05-query-routing.md) ·
[Module 07](../modules/07-range-and-timeseries.md)

## The problem

Lab 7 ended with an honest compromise: `vehicle_telematics` is partitioned for
time-window reads, but all its partitions sit on the coordinator — no extra
write capacity, no scale-out. Production telematics doesn't accept that
compromise. It needs **both** dimensions at once:

- **Distribute by `fleet_id`** — hash placement spreads every fleet's pings
  across workers and keeps fleet-local queries single-shard.
- **Partition by `recorded_at`** — range bounds keep spatial indexes small,
  let time predicates prune, and turn retention into a metadata operation.

This lab stacks the two layers on one table, then adds the geospatial piece
the platform actually ships: geofence matching with PostGIS.

## In this lab you will explore

- **Distributed partitioned tables** — what `create_distributed_table` does to
  a partitioned parent and its children
- **Two-layer pruning** — shard pruning *and* partition pruning in one plan
- **Spatial indexes inside shards** — a PostGIS GiST index that lives on the
  workers, not the coordinator
- **Reference-table geofencing** — joining a sharded ping stream to a geofence
  table that exists in full on every worker
- **Cluster-wide retention** — dropping an expired partition and watching it
  vanish from every worker at once

> **Prerequisite:** complete Lab 7. This lab assumes
> `vehicle_telematics` exists as a *local* partitioned table holding 22,000
> pings, and `fleets`, `vehicles`, `trips` are distributed by `fleet_id`,
> co-located with 8 shards each.

Connect:

```bash
psql -h localhost -p 5432 -U postgres -d fleet
```

---

## Task 1 — Distribute the partitioned parent

**Goal:** turn the local partitioned `vehicle_telematics` into a distributed
table, keeping it co-located with the rest of the fleet-keyed data:

```sql
SELECT create_distributed_table('vehicle_telematics', 'fleet_id', colocate_with := 'fleets');
```

Now inspect what Citus actually built:

```sql
SELECT table_name, count(*) AS shards
FROM citus_shards
WHERE table_name::text LIKE 'vehicle_telematics%'
GROUP BY table_name
ORDER BY table_name;
```

**Questions:**

1. How many shard rows appear — and why is it more than the 8 you'd see for an
   unpartitioned table?
2. Compare `SELECT count(*) FROM vehicle_telematics;` with the 22,000 you
   loaded. Did distribution lose any rows?
3. A PK on this table would have to satisfy *two* constraint layers. Without
   looking it up: which columns must it include at minimum?

---

## Task 2 — Two-layer pruning in one plan

**Goal:** observe the coordinator prune by `fleet_id` (shard routing) while
PostgreSQL prunes by `recorded_at` (partition bounds) *inside* the routed task.

```sql
EXPLAIN (COSTS OFF)
SELECT vehicle_id, recorded_at, speed_kph
FROM vehicle_telematics
WHERE fleet_id = 101
  AND recorded_at >= '2026-11-14' AND recorded_at < '2026-11-15';
```

Read the plan bottom-up:

- **`Task Count: 1`** — hash of `fleet_id = 101` names one shard; the other
  fleets' shards are never contacted.
- **The scan inside the task** — which partition shard (`..._p2026_11_1X_...`)
  appears? Which partitions do *not*?

**Question:** change the window to cover Nov 14–15 *and* Nov 16
(`< '2026-11-17'`). How many partition scans appear inside the single task now?
Why is `Task Count` still 1?

---

## Task 3 — A spatial index that lives inside the shard

**Goal:** the geofencing hot path is *"pings of fleet F near point P in window
W"*. `ST_DWithin` on a `geography` value can use a GiST index — but the index
must be created on the **parent**, whereupon Citus builds it inside every
shard partition:

```sql
CREATE INDEX idx_telematics_geo
    ON vehicle_telematics USING GIST ((location::geography));
```

Note the cast: the seeded column is `geometry`; casting to `geography` makes
`ST_DWithin` measure **metres**, not degrees. The index has to match the
expression in the query — a plain `GIST (location)` index would not be usable
by the `::geography` predicate.

Now find Metro Cabs' pings within 2 km of the Newark Airport terminal
(`-74.17, 40.68`) on Nov 16:

```sql
EXPLAIN (COSTS OFF)
SELECT vehicle_id, recorded_at, speed_kph
FROM vehicle_telematics
WHERE fleet_id = 1
  AND recorded_at >= '2026-11-16' AND recorded_at < '2026-11-17'
  AND ST_DWithin(
        location::geography,
        ST_SetSRID(ST_MakePoint(-74.17, 40.68), 4326)::geography,
        2000);
```

**Question:** trace the whole access path in the plan. Which shard did the
coordinator pick, which partition inside it, and which index inside the
partition? How much of the 22,000 rows did the query *not* touch?

---

## Task 4 — Geofencing with a reference table

**Goal:** `service_zones` holds 5 geofence polygons and is still a local table
— which means a distributed join would have to drag it to the workers (or the
pings to the coordinator) on every query. Turn it into a **reference table** —
a full copy on every worker — so spatial joins run inside the shard task:

```sql
SELECT create_reference_table('service_zones');
```

Then answer *"which zones did Metro Cabs' vehicles ping from on Nov 16?"*:

```sql
EXPLAIN (COSTS OFF)
SELECT z.zone_name, count(*) AS pings
FROM vehicle_telematics t
JOIN service_zones z ON ST_Contains(z.boundary, t.location)
WHERE t.fleet_id = 1
  AND t.recorded_at >= '2026-11-16' AND t.recorded_at < '2026-11-17'
GROUP BY z.zone_name;
```

Run the query itself too — which zone dominates?

**Questions:**

1. The plan is `Task Count: 1` again — but look inside the task: which
   `service_zones_*` table appears in the join, and where does it live?
2. Why does a reference table beat a distributed `service_zones` here? What
   assumption about its size and change rate makes this safe?
3. `citus_tables` now shows `service_zones` as `reference` — check its
   `shard_count`. Why is it *not* 8?

---

## Task 5 — Retention: expire a partition across the cluster

**Goal:** the platform keeps 48 h of pings. Nov 14 is outside the window.
First prove the partition exists everywhere as shards:

```sql
SELECT table_name, shardid, nodename
FROM citus_shards
WHERE table_name = 'vehicle_telematics_p2026_11_14'::regclass
ORDER BY shardid;
```

Then expire it:

```sql
DROP TABLE vehicle_telematics_p2026_11_14;
```

Verify, both through metadata and the remaining row count:

```sql
SELECT table_name, count(*) FROM citus_shards
WHERE table_name::text LIKE 'vehicle_telematics%' GROUP BY 1 ORDER BY 1;

SELECT count(*) FROM vehicle_telematics;   -- 21,000
```

**Questions:**

1. The `DROP` ran on the coordinator. How did the shard tables on all three workers
disappear without you touching them?
2. Compare this with `DELETE FROM vehicle_telematics WHERE recorded_at <
   '2026-11-15'` — what does the `DELETE` pay that the `DROP` doesn't (I/O,
   dead tuples, `VACUUM`)?
3. Your Lab 7 retention plan said *detach* for archiving. If you'd detached
   `..._p2026_11_14` instead, what would be different now?

---

## Stretch — attach tomorrow's partition

Operators roll partitions forward before midnight. Try it:

```sql
CREATE TABLE vehicle_telematics_p2026_11_17 (
  LIKE vehicle_telematics INCLUDING DEFAULTS
);
```

Attaching a bounded partition to a distributed parent automatically creates
its shards on the workers — check `citus_shards` again after
`ALTER TABLE ... ATTACH PARTITION`. (The `MAXVALUE` partition will reject a
new bounded range; what sequence of detach/attach/reattach would production
rotation need?)

---

## Finishing up

You have now seen the full production shape: **sharding gives you machines,
partitioning gives you time, reference tables give you dimensions, and a GiST
index inside each shard gives you space** — all visible in one `EXPLAIN`.

You should be able to explain, with evidence:

- why a distributed partitioned table produces `partitions × shards` objects,
- how `fleet_id` routing and `recorded_at` pruning compose in a single plan,
- why a geography-expression GiST index must be created on the parent,
- why geofences belong in a reference table,
- why retention by `DROP` beats retention by `DELETE`, and how the drop
  propagates to every worker.

*Stuck? See [solutions/lab-08-solutions.md](solutions/lab-08-solutions.md).*
