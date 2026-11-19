# Lab 7 — Solutions: Range Partitioning

## Tasks 1–2 — range placement

Partitions and bounds:

```text
 vehicle_telematics_p2026_11_14 | FROM ('2026-11-14') TO ('2026-11-15')
 vehicle_telematics_p2026_11_15 | FROM ('2026-11-15') TO ('2026-11-16')
 vehicle_telematics_p2026_11_16 | FROM ('2026-11-16') TO (MAXVALUE)
```

Rows per partition:

```text
 vehicle_telematics_p2026_11_14 |  1000
 vehicle_telematics_p2026_11_15 |  1000
 vehicle_telematics_p2026_11_16 | 20000
```

- **All 20,000 new pings landed in `p2026_11_16`** — the "current" partition.
  The two older partitions sit nearly idle for writes.
- The one-day query plan scans **exactly one partition**
  (`Seq Scan on vehicle_telematics_p2026_11_14`) — partition pruning discards
  the rest without reading them.

**Interpretation:** range placement makes time-windowed *reads* extremely
efficient (read only the shards whose ranges overlap the window) but
concentrates all *writes* on the single shard holding "now" — the hot-shard
problem. Hash placement is the mirror image: perfectly balanced writes, but a
time-range read must touch every shard.

## Task 3 — physical children and pruning

`tableoid::regclass` identifies the actual child storing each returned row.
Expected counts from Task 1's seed are 1,000, 1,000, and 20,000; their sum is
22,000, equal to the parent query. No second copy of these rows is stored in the
partitioned parent.

The midnight probes identify the Nov 14, Nov 15, and Nov 16 partitions
respectively. Nov 15 midnight is excluded from the Nov 14 partition and
included in the Nov 15 partition.

These are local PostgreSQL children on the coordinator, described by
`pg_inherits`. They are not Citus shard placements. The `fleet_id = 1` plan
retains all three children because that predicate supplies no bound on
`recorded_at`. The exact scan nodes depend on indexes and planner decisions;
the important observation is which child relations remain eligible.

A time predicate can prune children even when each retained child uses a
sequential scan. Conversely, a fleet index can speed access inside each child
without allowing time-based pruning. Shard routing, partition pruning, and index
access are three distinct decisions.

## Task 4 — retention and future bounds

The candidate is `vehicle_telematics_p2026_11_14`: its upper bound is Nov 15
and it contains 1,000 rows. Detaching it would leave 21,000 rows visible
through the parent, while preserving the detached table as a standalone
archive. Dropping the child removes its data; neither operation needs a
row-by-row delete when the whole interval expires. Real operations still need
backup, lock, and retention planning. No detach or drop is performed in this
lab — Lab 8 performs the distributed version.

The Nov 16 partition extends to `MAXVALUE`, so a new Nov 17 range would overlap
it and be rejected. Production daily rotation uses bounded future partitions,
or carefully reorganizes the catch-all and its rows before adding new ranges.

A native partitioned-parent primary key must include `recorded_at` so its
uniqueness can be enforced within partitions. If the table is also distributed
by `fleet_id` (Lab 8), Citus's distribution-key requirement stacks on top: the
PK must include **both** `fleet_id` and `recorded_at` — e.g.
`(fleet_id, recorded_at, ping_id)`. That still does not establish global
uniqueness of `ping_id` alone.

## Task 5 — strategy for weekly reports

**Answer:** **Range placement on `recorded_at`.** The weekly report reads one
contiguous time window, so range shards let the planner touch only the
partitions covering that week instead of fanning out to every shard.

**Trade-off:** every new insert lands in the "current" partition, so writes
concentrate on one hot shard while older shards idle — the classic
range-sharding write hotspot. (Mitigations in real systems: rotate and retire
old partitions, sub-shard the hot range, or accept it when read latency matters
more than write balance. Lab 8 shows the combined answer: hash by `fleet_id`
for write spread *plus* range partitions for time pruning.)
