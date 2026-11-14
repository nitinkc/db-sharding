# Module 07 — Range Placement & Time-Series Workloads

Citus distributes by hash. Many real sharded systems (BigTable, Spanner,
MongoDB ranges, PG partitions) place rows by **range**: each shard owns a
contiguous key interval. Lab 6, Task 8 models range placement with native
PostgreSQL partitions — each partition behaves exactly like one range shard.

## What we observed

```
order_events (22,000 rows)
├── p2026_03_01  [03-01 → 03-02)   1,000 rows   ◄── old, cold
├── p2026_03_02  [03-02 → 03-03)   1,000 rows   ◄── old, cold
└── p2026_03_03  [03-03 → ∞)      20,000 rows   ◄── "now": HOT for writes
```

- A one-day query scanned **exactly one partition** — the planner pruned the
  other two before reading a row. Range shards make windowed reads optimal.
- All 20,000 new events landed in the **latest** partition. Monotonic keys +
  range placement ⇒ one hot shard absorbs every write.

## Hash vs range, head to head

| | Hash | Range |
|---|---|---|
| Point lookup (`id = ?`) | 1 shard | 1 shard |
| Range query (`time BETWEEN a AND b`) | fans out to *all* shards | only overlapping shards |
| Monotonic write stream | balanced everywhere | all writes → newest shard |
| Rebalance/merge | move token ranges | split/merge natural boundaries |
| Skew risk | low | depends on key distribution |

## Which for the weekly-report workload? (Lab 6, Task 9)

Reports read contiguous time windows ⇒ **range**. Cost: the write hotspot on
"now". Real-world mitigations:

- **Partition rotation:** create next day's partition ahead of time; drop or
  archive the oldest (cheap DDL, no deletes). This is also how retention gets
  implemented — `DROP TABLE` beats `DELETE` by orders of magnitude.
- **Compound key:** range on time *then* hash on tenant within each range —
  combines pruning with write spread (TimescaleDB chunks do roughly this).
- **Split the hot range** when it outgrows siblings.

## Connecting back to Citus

Citus won't range-place distributed tables — but it composes with PG
partitioning (distribute a partitioned table; each partition is itself
distributed) and with TimescaleDB chunks conceptually. The lab's takeaway is
the *strategy*, not the tool: match placement to the dominant access pattern.

![Range versus hash placement for time-series reads and writes](../diagrams/range-vs-hash-timeseries.svg)

**Next:** [Module 08 — Capstone](08-capstone.md)
