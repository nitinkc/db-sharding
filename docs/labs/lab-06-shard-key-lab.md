# Lab 6 — Choosing a Shard Key: Good Queries and Bad Queries

**Module reference:** [Module 02](../modules/02-sharding-strategies.md) ·
[Module 04](../modules/04-choosing-a-shard-key.md) ·
[Module 05](../modules/05-query-routing.md)

## The problem

Deciding to split a table across a cluster is only the first decision. The next
one is harder: **which column to split on**. That column is the shard key —
Citus calls it the *distribution column*. It is the single most important
decision in a sharded design, and it is painful to change once data is in
place.

In this lab you work with the fleet platform's tables under different shard
keys and investigate, from the evidence, what each choice does to where rows
are stored and how queries run.

## In this lab you will explore

- **Starting state** — which tables Citus already manages, and by which column
- **Hash placement** — how Citus maps consecutive fleet ids to shards, and
  whether the same id always lands in the same place
- **Cardinality and spread** — how evenly a distributed table's rows spread,
  and what decides that
- **Query routing** — how many shards a fleet lookup touches under two
  different shard keys
- **Good queries vs bad queries** — what a single-shard *router* query and an
  all-shard *scatter-gather* query look like in `EXPLAIN`, and which shard key
  produces each
- **Co-location** — how related tables that share a shard key behave in a join
- **Shard key immutability** — what happens when you try to change the shard
  key of an existing row

## Your environment

A Citus cluster runs in Docker. You connect to its coordinator on
`localhost:5432`. Database: `fleet` — user `postgres` — no password.

The platform's tables:

| Table | One row per | Columns you will use |
| --- | --- | --- |
| `fleets` | fleet operator | `fleet_id` (PK), `fleet_name`, `home_city`. Metro Cabs is `fleet_id` 1, Harbor Logistics 2, Golden Gate Rides 3. |
| `vehicles` | vehicle + last GPS fix | `fleet_id` (the operating fleet), `vehicle_id`, `license_plate`, `status`, `last_known_location` (PostGIS point). PK `(fleet_id, vehicle_id)`. |
| `trips` | completed trip | `fleet_id` (the operating fleet), `trip_id`, `vehicle_id`, `distance_km`, `fare_usd` |
| `vehicles_by_region` | vehicle | `vehicle_id`, `license_plate`, `region` |
| `service_zones` | geofence polygon | `zone_id`, `zone_name`, `boundary` (PostGIS polygon) |

Connect at any time:

```bash
psql -h localhost -p 5432 -U postgres -d fleet
```

> **Prerequisite:** complete Labs 1–5 first. This lab assumes `fleets` is
> distributed by `fleet_id` into 8 shards.

---

## Task 1 — Inspect the starting state

**Goal:** Before you change anything, find out which of the platform's tables
(`fleets`, `vehicles`, `trips`, `vehicles_by_region`, `service_zones`) Citus
already manages, and with which distribution column.

Useful view: `citus_tables` (columns: `table_name`, `citus_table_type`,
`distribution_column`, `shard_count`, `colocation_id`).

**Question:** Which statement matches the starting state of the cluster?

a) All five tables are distributed
b) `fleets` is distributed by `fleet_id`; `vehicles`, `trips`,
   `vehicles_by_region`, and `service_zones` are still local tables
c) `fleets` is distributed by `fleet_name`; nothing else is distributed
d) Nothing is distributed

---

## Task 2 — Hash placement: map consecutive fleets to shards

![Fleet IDs hashed into shard token ranges across workers](../diagrams/hash-placement.svg)

Use this as a model of the routing steps, not a substitute for the actual shard
IDs returned by your cluster.

**Goal:** Fleet ids are handed out in order: 1, 2, 3, and so on. `fleets` is
distributed by `fleet_id`. Investigate where Citus places consecutive ids:

1. Find the shard that owns each `fleet_id` from 1 to 8:

   ```sql
   SELECT id, get_shard_id_for_distribution_column('fleets', id) AS shardid
   FROM generate_series(1, 8) AS id;
   ```

2. Run the lookup a second time. Does any answer change?

**Question:** What do you observe about how consecutive fleet ids map to
shards? (Think: is the mapping sequential? Random? Repeatable?)

---

## Task 3 — Cardinality and spread: distribute `vehicles_by_region` by `region`

**Goal:** `vehicles_by_region` holds one row per vehicle, with the vehicle's
home region, and is still a local table. A tempting shard key is `region` —
it's a short, readable label and every report filters on it. Distribute it
yourself and then investigate how its rows are spread:

1. Distribute the table by `region` into 8 shards:

   ```sql
   SELECT create_distributed_table(
     'vehicles_by_region', 'region', shard_count := 8);
   ```

2. How many distinct regions does the table contain?

   ```sql
   SELECT count(DISTINCT region) FROM vehicles_by_region;
   ```

3. How many of the 8 shards hold any rows?

   ```sql
   SELECT * FROM run_command_on_shards(
     'vehicles_by_region', 'SELECT count(*) FROM %s');
   ```

4. What share of all rows does the fullest shard hold?

<quiz>
Which statement matches what you found?

- [x] Rows spread evenly across all 8 shards
- [ ] Only 5 shards hold rows, and one shard holds a large majority of all rows
- [ ] Every shard holds exactly the same number of rows
- [ ] All rows landed in one shard

</quiz>

Then answer: **why** does the spread look this way? What property of the
distribution column decides it?

---

## Task 4.1 — Query routing: distribute `vehicles` by `vehicle_id`

**Goal:** Each row of `vehicles` is one vehicle. Its primary key is
`(fleet_id, vehicle_id)`, so either column could be the shard key. Distribute
it by the *vehicle* id, in a co-location group of its own:

| Setting | Required value |
| --- | --- |
| Table | `vehicles` |
| Distribution column | `vehicle_id` |
| Number of shards | 8 |
| Co-location | A group of its own — not shared with any other table |

/// details | Hint
    type: hint

```sql
SELECT create_distributed_table(
  'vehicles', 'vehicle_id', shard_count := 8, colocate_with := 'none');
```

///

## Task 4.2 — Query routing: inspect a fleet lookup on `vehicles`

**Goal:** The platform's most common request is *"show me this fleet's
vehicles"*. `vehicles` is now distributed by `vehicle_id`. Investigate how
Citus would run that request for Metro Cabs (`fleet_id = 1`) — including how
many shard queries the plan contains:

```sql
EXPLAIN (COSTS OFF) SELECT * FROM vehicles WHERE fleet_id = 1;
```

Count the `Task` nodes (each one is a query sent to a shard) and look at the
`Tasks Shown` line.

**Question:** What does the query plan show — one shard query, or many? Why?

---

## Task 5.1 — Query routing: redistribute `vehicles`, distribute `trips`

**Goal:** Reconfigure to:

| Table | Distribution column | Co-located with |
| --- | --- | --- |
| `vehicles` | `fleet_id` | `fleets` |
| `trips` | `fleet_id` | `fleets` |

`vehicles` is currently distributed by `vehicle_id`. A table's distribution
column **can't be changed in place**: turn it back into a regular table first,
then distribute it again:

```sql
SELECT undistribute_table('vehicles');
SELECT create_distributed_table('vehicles', 'fleet_id', colocate_with := 'fleets');
```

Note: `colocate_with` and `shard_count` can't be given together — co-location
means *same shard count and same placement as the other table*, so Citus
inherits `fleets`' 8 shards automatically.

`trips` is still a local table — each row records one completed trip, and its
`fleet_id` is the fleet that operated it:

```sql
SELECT create_distributed_table('trips', 'fleet_id', colocate_with := 'fleets');
```

## Task 5.2 — Query routing: inspect the fleet lookup again

![Comparison of a single-shard route and a scatter-gather query](../diagrams/query-routing-fanout.svg)

Compare the two paths with your plans from Tasks 4.2 and 5.2. Look for task
count, workers contacted, and whether the coordinator must merge results.

**Goal:** `vehicles` is now distributed by `fleet_id`, co-located with
`fleets`. Investigate how Citus runs *"show me this fleet's vehicles"* now:

```sql
EXPLAIN (COSTS OFF) SELECT * FROM vehicles WHERE fleet_id = 1;  -- Metro Cabs
EXPLAIN (COSTS OFF) SELECT * FROM vehicles WHERE fleet_id = 2;  -- Harbor Logistics (never looked up before)
```

For each: how many shard queries does the plan contain, and on which node?

**Question:** What do the query plans show now, compared with Task 4.2?

---

## Task 6 — Co-location: join two co-located tables

![Matching fleet and vehicle shards joined locally on the same worker](../diagrams/colocation-join.svg)

Follow one fleet's rows across the two tables. Matching shard-key values and
co-location let the worker perform the join without shipping those rows between
workers. Confirm this with your metadata and query plan.

**Goal:** `fleets`, `vehicles`, and `trips` are all distributed by
`fleet_id`. Investigate:

1. The co-location group (`colocation_id`) of each of the three tables:

   ```sql
   SELECT table_name, colocation_id FROM citus_tables
   WHERE table_name IN ('fleets','vehicles','trips')::regclass[];
   ```

   (If `IN` on regclass array is awkward, run three queries or use
   `WHERE table_name::text IN ('fleets','vehicles','trips')`.)

2. How many shard queries Citus plans for a join listing a fleet's name next
   to each of its vehicles:

   ```sql
   EXPLAIN (COSTS OFF)
   SELECT f.fleet_name, v.license_plate
   FROM fleets f JOIN vehicles v USING (fleet_id)
   WHERE f.fleet_id = 1;
   ```

   Then repeat for `fleet_id = 3` (Golden Gate Rides).

**Question:** What do the co-location groups and the join plans show? Where does
the join actually run?

---

## Task 7.1 — Shard key immutability: try to change a row's shard key

**Goal:** Find out what happens when you try to change the `fleet_id` of an
existing fleet.

1. Add a test fleet:

   ```sql
   INSERT INTO fleets VALUES (20001, 'shardkey_demo', 'Shard Key Demo');
   ```

2. Try to change that fleet's `fleet_id` to 20002 with an `UPDATE`. Note
   exactly what happens — read the error.

3. Move the fleet instead: in a **single transaction**, insert fleet 20002
   with fleet name `shardkey_demo_moved` (same home city) and delete
   fleet 20001.

When you finish, `fleets` must contain fleet 20002 (`shardkey_demo_moved`)
and no fleet 20001.

/// details | Hint for step 3
    type: hint

```sql
BEGIN;
INSERT INTO fleets VALUES (20002, 'shardkey_demo_moved', 'Shard Key Demo');
DELETE FROM fleets WHERE fleet_id = 20001;
COMMIT;
```

///

## Task 7.2 — Shard key immutability: why the update was refused

**Goal:** Citus refused to change fleet 20001's `fleet_id` to 20002 with an
`UPDATE`, but accepted the same change as insert + delete. Investigate:

1. Which shard owns `fleet_id = 20001`, which owns `fleet_id = 20002`, and
   which worker holds each of those shards:

   ```sql
   SELECT get_shard_id_for_distribution_column('fleets', 20001) AS old_shard,
          get_shard_id_for_distribution_column('fleets', 20002) AS new_shard;
   ```

   Then look up those shard ids in `citus_shards`.

2. Does Citus accept an `UPDATE` that changes a *different* column of
   fleet 20002 — e.g. `home_city`?

   ```sql
   UPDATE fleets SET home_city = 'Shard Key Demo (moved)'
   WHERE fleet_id = 20002;
   ```

**Question:** What explains Citus's behaviour? (Hint: an UPDATE that changes
the distribution column is really a **move between shards** — possibly between
machines — not an in-place update.)

---

## Finishing up — what a good query and a bad query look like

You now have a sharded schema: `fleets`, `vehicles`, and `trips` distributed by
`fleet_id` and co-located; `vehicles_by_region` distributed by `region`;
`service_zones` still local. And you have seen both shapes a distributed query
can take:

| | Good query (router) | Bad query (scatter-gather) |
| --- | --- | --- |
| Example | `WHERE fleet_id = 1` on a `fleet_id`-sharded table | `WHERE fleet_id = 1` on a `vehicle_id`-sharded table |
| `EXPLAIN` signature | `Task Count: 1` — one shard, one worker | `Task Count: 8` — every shard, all three workers |
| Why | The filter column *is* the shard key: hash → shard → done | The filter column isn't the shard key: Citus must ask everyone |
| Joins | Co-located tables join inside the same task | Non-co-located joins drag rows across the network |

The shard key decides which column gets the fast path. Everything else pays
the fan-out tax — which is why the key is chosen from the workload's most
common predicates, and why it's effectively immutable once chosen.

You should now be able to explain, with evidence from this cluster:

- why hash placement spreads consecutive ids evenly but scatters range queries,
- why a low-cardinality shard key (`region`) creates skewed shards,
- why `fleet_id` turns a fleet lookup into a single-shard query while
  `vehicle_id` fans out to every shard,
- what co-location buys you in a join,
- why shard keys are effectively immutable.

**Next:** [Lab 7 — Range partitioning](lab-07-range-partitioning.md) — hash
placement solved "which machine", but not "which time window". Partition the
telematics stream by `recorded_at` and watch the planner prune.

*Stuck? See [solutions/lab-06-solutions.md](solutions/lab-06-solutions.md).*
