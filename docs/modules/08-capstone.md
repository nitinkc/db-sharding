# Module 08 — Capstone: Design the Dispatch Workload

Apply everything. No guided steps — you make the calls and defend them with
evidence from the cluster.

## Scenario

The platform adds driver management. Two new tables:

```sql
CREATE TABLE drivers (
  fleet_id   bigint NOT NULL,
  driver_id  bigint NOT NULL,
  full_name  text NOT NULL,
  license_no text NOT NULL,
  hired_on   date NOT NULL DEFAULT '2020-01-01',
  PRIMARY KEY (fleet_id, driver_id)
);

CREATE TABLE shifts (
  fleet_id   bigint NOT NULL,
  shift_id   bigint NOT NULL,
  driver_id  bigint NOT NULL,
  vehicle_id bigint NOT NULL,
  started_at timestamptz NOT NULL,
  ended_at   timestamptz,
  PRIMARY KEY (fleet_id, shift_id)
);

INSERT INTO drivers (fleet_id, driver_id, full_name, license_no)
SELECT s.fleet_id, d, 'Driver ' || s.fleet_id || '-' || d,
       'DL-' || s.fleet_id || '-' || d
FROM fleets s, generate_series(1,4) AS d;              -- 40,000 drivers

INSERT INTO shifts (fleet_id, shift_id, driver_id, vehicle_id, started_at, ended_at)
SELECT s.fleet_id, h, (h % 4) + 1, (h % 4) + 1,
       timestamp '2026-11-01' + ((s.fleet_id * 3 + h * 7) % 360) * interval '1 hour',
       timestamp '2026-11-01' + ((s.fleet_id * 3 + h * 7) % 360) * interval '1 hour' + interval '8 hours'
FROM fleets s, generate_series(1,4) AS h;              -- 40,000 shifts
```

Run the DDL + seed on the coordinator first (they're local tables).

## Dominant queries (given by product)

1. `SELECT * FROM drivers WHERE fleet_id = ?` — fleet roster page
   (highest traffic).
2. `SELECT * FROM drivers d JOIN shifts s USING (fleet_id, driver_id)
    WHERE d.fleet_id = ?` — a fleet's driver shift history.
3. Weekly utilization report:
   `SELECT date_trunc('week', started_at) w, count(*) FROM shifts GROUP BY 1`
   (run by dispatch analytics, off-hours).

## Your tasks

1. **Choose a distribution column for `drivers`** and justify it against the
   five criteria (cardinality, uniformity, query alignment, co-location,
   immutability). Note the PK constraint implications.
2. **Distribute `drivers` and `shifts`** with co-location that serves
   query 2 optimally.
3. **Prove it:** `EXPLAIN (COSTS OFF)` queries 1 and 2 for `fleet_id = 1` and
   `fleet_id = 7`. Record `Task Count` for each.
4. **Analyze the trade-off:** what does query 3 (no `fleet_id` filter) cost
   under your design? Could a different design serve it better — and what would
   it cost queries 1–2?
5. **Break something:** try `UPDATE drivers SET fleet_id = fleet_id + 100000
   WHERE fleet_id = 1`. Explain the error and fix the design constraint it
   reveals.
6. **Simulate growth:** `SELECT citus_add_node(...)` can't add a 4th worker
   (only three exist) — instead, reason it through: after adding `worker4`, how
   would your 8 shards redistribute, and which Citus command does it?

## Self-check rubric

- [ ] `drivers` and `shifts` share a `colocation_id` with `fleets` (or you
      can defend a different grouping).
- [ ] Query 1 and query 2 both plan as `Task Count: 1`.
- [ ] You can state why query 3 fans out — and that it's acceptable here
      (off-hours batch) rather than a design error.
- [ ] You predicted the Task-5 error before running it.
- [ ] You named `rebalance_table_shards()` for task 6 and predicted a 2/2/2/2
      (or 3/3/2 → 2/2/2/2) placement split.

## Stretch goals

- Extend [Lab 7's partitioning investigation](../labs/lab-07-range-partitioning.md#task-3-connect-partitions-to-the-shard-investigation)
  into a design for time-partitioned `shifts`. Plan it separately before changing
  the working capstone tables: retain fleet distribution, choose bounded monthly
  ranges, and compare fleet-only, time-only, and fleet-plus-time queries.
  Explain which layer prunes partitions and which routes worker tasks.
- Identify how partitioning `shifts` on `started_at` changes the existing
  `(fleet_id, shift_id)` primary key: a native partitioned-parent key must also
  include the time key. Explain the consequences for the
  `drivers ⋈ shifts` join, whose current join columns have no timestamp, and
  propose a compatible key/join design rather than assuming the original
  constraints work unchanged.
- Write a retention plan for expired telematics, like Lab 8's partition drop.
  How does dropping a partition across a Citus cluster differ from a row-by-row
  `DELETE` — in I/O, locking, and `VACUUM` debt? How does *detaching* differ
  from dropping?
- Make `service_zones` a reference table (`create_reference_table`) — Lab 8
  does this — and explain when that beats distributing it. What breaks if a
  geofence grows to millions of rows?
- Design a `region`-sharded alternative for `drivers`. What queries get faster,
  which get catastrophic, and why did the fleet-side key still win?

*This capstone has no single right answer — the rubric rewards designs whose
evidence (EXPLAIN output, metadata queries) supports the stated trade-offs.*
