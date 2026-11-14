# Module 07 — Partitioning, Range Placement & Time-Series

Bazaar now has two different workloads: seller storefronts need fast tenant
lookups, while growing `order_events` needs time-window reports and retention.
Keep the `seller_id` sharding design from Labs 3–6; add a second tool rather
than replacing it: **native PostgreSQL table partitioning**.

## Where this fits in the labs

1. Labs 1–2 distinguish a logical table from where its rows are stored.
2. Labs 3–5 distribute `sellers` across worker shards and trace a row's location.
3. Lab 6, Tasks 4–6 use the distribution key to reduce distributed query work.
4. [Lab 6, Tasks 8.1–8.4](../labs/lab-06-shard-key-lab.md#task-81-range-placement-build-a-range-partitioned-table)
   apply the same reasoning to partitions: locate rows, inspect plans, and
   explain which physical tables a query can skip.
5. The capstone combines these decisions in the orders workload.

## Partitioning is not sharding

A partitioned table is a **logical parent** with rows stored in child tables.
An insert into the parent is routed to a child using its partition key and
bounds. A select from the parent reads the relevant children. The parent itself
has no row storage.

| Property | Native partitioning in this lab | Citus distribution in earlier labs |
| --- | --- | --- |
| Physical location | Child tables on the coordinator | Shard tables across workers |
| Routing key | `event_time` | `seller_id` |
| Routing rule | Declared time bounds | Hash token mapped to a shard |
| Read optimization | Skip irrelevant partitions | Skip irrelevant shards |
| Main benefit here | Time-window reads and retention | Scale tenant storage and query work across nodes |
| Does it add machines? | No | Uses registered workers |

A local partition is **not** a worker or a distributed shard. It models range
placement, but does not model network hops, worker failure, or distributed
transactions. PostgreSQL partitions can also be combined with Citus distribution.

## Three native partitioning methods

| Method | Routing rule | Bazaar use case | Main caution |
| --- | --- | --- | --- |
| `RANGE` | Lower bound included, upper bound excluded | Daily event history | Newest interval receives current writes |
| `LIST` | Explicit sets of values | Region-specific operational data | New values need coverage; popular values can dominate |
| `HASH` | Hash of key, modulus and remainder | Spread rows among local child tables | Still one server; not Citus sharding |

Choose bounds for the workload, not one partition per row or seller. Too many
partitions add planning and maintenance overhead. Partitioning is not an
automatic performance improvement for every table.

## Follow one event through the parent

In Lab 6 the parent is `order_events`, partitioned by `event_time`:

```text
INSERT INTO order_events (...)
                |
                v
        route by event_time
                |
                +-- [March 1, March 2)  -> p2026_03_01:  1,000 rows
                +-- [March 2, March 3)  -> p2026_03_02:  1,000 rows
                +-- [March 3, infinity) -> p2026_03_03: 20,000 rows
```

An event at exactly `2026-03-02 00:00:00` belongs in the **second** partition.
Non-overlapping, half-open intervals avoid ambiguity at midnight. Without a
matching partition or a `DEFAULT` partition, an insert fails. A default partition
can catch gaps but needs monitoring and care when adding new explicit bounds.

The final `MAXVALUE` partition is intentionally simple for this lab. It also
captures all future days: adding another daily partition would overlap it.
Production rotation requires bounded intervals created ahead of time, or an
explicit plan to reorganize a catch-all partition and its existing data.

## Pruning versus indexes

**Partition pruning** uses predicates and partition bounds to avoid scanning
irrelevant children. An **index** finds matching rows inside a retained child.
These are separate optimizations and can be useful together.

```sql
EXPLAIN (COSTS OFF)
SELECT * FROM order_events
WHERE event_time >= timestamp '2026-03-01'
  AND event_time < timestamp '2026-03-02';
```

This literal time window allows PostgreSQL to keep only the March 1 partition.
Its scan may still be a sequential scan: pruning worked even without an index.
For other query forms pruning can happen during execution; read the plan rather
than assuming a particular node name.

Compare with `WHERE seller_id = 1`: a seller predicate alone does not constrain
`event_time`, so all three partitions remain eligible. An index on `seller_id`
could help within them, but cannot supply a missing time bound. Prefer direct,
type-compatible predicates on the partition key; wrapping it in an expression
can prevent the pruning you expected.

## Prove row location and conservation

Use PostgreSQL's `tableoid` system column to identify the physical child behind
a row returned through the parent:

```sql
SELECT tableoid::regclass AS physical_partition, count(*) AS rows
FROM order_events
GROUP BY tableoid
ORDER BY physical_partition::text;
```

The counts sum to 22,000, just as the per-shard counts summed to the logical
`sellers` count in Lab 5. `pg_inherits` describes parent/child membership;
`citus_shards` describes distributed shard placement, not these local partitions.

## Retention and constraints

Daily partitions make an entire expired interval a lifecycle unit. Operators can
detach a child to keep it as a standalone archive table, or drop an expired child
to remove its data. Both need an explicit retention decision, backup strategy,
and lock planning. Detaching does not delete the child, but immediately changes
which rows are visible through the parent. Lab 6 only plans retention; it keeps
all data available for later exercises.

A primary or unique constraint on a native partitioned parent must include all
partition-key columns (with additional limitations for expression keys). For
example, a time-partitioned event table can use `(event_time, event_id)`, but this
does **not** guarantee that `event_id` alone is globally unique. This resembles
the shard-key constraint from Module 04, but applies to a different layer.

## Range reads versus current writes

![Range versus hash placement for time-series reads and writes](../diagrams/range-vs-hash-timeseries.svg)

Time windows can prune range partitions, while a monotonically increasing event
time concentrates writes in the newest interval. Hashing can spread many distinct
keys, but does not preserve time locality or eliminate skew from a dominant key.
In this local lab every partition is still on the same coordinator, so creating
more partitions does not add server write capacity.

## Combine partitioning and distribution deliberately

For a larger Bazaar event workload, a possible two-layer design is:

- **Partition by time** for pruning and retention.
- **Distribute by seller** within those partitions for worker-level write spread
  and seller-local operations.

A seller-plus-time predicate can benefit from both layers. A time-only report
may prune old partitions but still fan out across the retained distributed
partitions' shards. More partitions also mean more shard objects to manage.
Native partitioned-parent uniqueness must include the time key; Citus uniqueness
also needs the distribution key. Validate the combined DDL and supported
operations against the deployed Citus version before adopting this design.

The core lab deliberately keeps `order_events` local, preserving the earlier
seller-sharding experiment and making each layer independently observable.

**Practice:** complete [Lab 6, Tasks 8–9](../labs/lab-06-shard-key-lab.md#task-81-range-placement-build-a-range-partitioned-table).

## Quick check

<quiz>
A `RANGE` partition covers `event_time` from `2026-01-01` to `2026-02-01`. Which row lands in it?
- [x] `event_time = '2026-01-01'` — the lower bound is included
- [ ] `event_time = '2026-02-01'` — the upper bound is included
- [ ] Both
- [ ] Neither

Lower bound included, upper bound excluded. `2026-02-01` belongs to the *next* partition.
</quiz>

<quiz>
What is the key difference between a native Postgres partition and a Citus shard?
- [ ] Partitions use hash routing; shards use range routing
- [ ] Partitions can be pruned; shards cannot
- [x] Partition children live on the same node — they add no machines; shards live across workers
- [ ] There is no difference — the terms are interchangeable

Partitioning splits a table inside one node; sharding distributes slices across nodes. You can combine them deliberately (a distributed table whose shards are themselves partitioned).
</quiz>

<quiz>
A daily-partitioned `order_events` table gets a query for `event_time >= now() - interval '7 days'`. What does pruning do?
- [ ] Moves old partitions to cheaper storage
- [x] Skips scanning partitions whose bounds can't match the filter
- [ ] Routes the query to a single worker
- [ ] Builds an index on the fly

Partition pruning is the read-side win: irrelevant children are excluded at plan time, like shard pruning on the distributed side.
</quiz>

**Next:** [Module 08 — Capstone](08-capstone.md)
