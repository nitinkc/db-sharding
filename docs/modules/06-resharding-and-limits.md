# Module 06 — Resharding, Rebalancing, and the Limits

## Adding a node

```sql
SELECT citus_add_node('worker3', 5432);
SELECT rebalance_table_shards();
```

The new worker starts empty. The rebalancer moves shard *placements* until each
node holds a fair share — for our 8-shard / 3-worker world: 3, 3, 2. Logical
shards don't change; only which node hosts them moves. Queries keep working
during the move (metadata flips at the end).

## Rebalancing ≠ resharding

| | Rebalance | Reshard / redistribute |
|---|---|---|
| What changes | Which *node* hosts each shard | Number of shards, or the shard key itself |
| Trigger | `citus_add_node` + `rebalance_table_shards()` | `undistribute_table` + `create_distributed_table` |
| Data moved | Whole shards (cheap per row) | Every row re-routed (expensive) |
| When | Cluster grows; skew drift | Wrong initial design |

This is why shard count and shard key are front-loaded decisions (Module 04).

## Tenant isolation

A "celebrity seller" (the bazaar equivalent of a celebrity's Twitter account)
can overload one shard even under a good key. Citus offers tenant isolation
(`isolate_tenant_to_new_shard`) — split that tenant onto its own shard so the
noisy neighbor stops hurting others. The general concept exists in every
sharded system as *shard splitting* or *dedicated shards*.

## CAP and what sharding does to consistency

Within a shard you keep full Postgres ACID. Across shards:

- **Consistency:** multi-shard writes need 2PC to stay atomic; Citus does this
  but it's slower and has more failure surface.
- **Availability:** a dead worker makes its shards unreadable unless you run
  shard replication (each placement on >1 node) — that's replication *inside*
  the sharded system.
- **Partition tolerance:** during a network split, the coordinator can't reach
  some shards — queries that need them fail; single-shard queries to reachable
  shards still work.

Design takeaway: keep transactions and hot reads **single-shard wherever
possible**; treat cross-shard operations as the exception you pay for
deliberately.

## Operational limits worth knowing

- Unique/PK/FK constraints must include the distribution column.
- `UPDATE` on the distribution column is refused (Lab 6, Task 7).
- Some SQL shapes can't run distributed (certain subqueries, `INSERT ... SELECT`
  across non-co-located tables, sequences are per-node).
- Reference tables help for joins to small dimensions — every worker already
  has the whole table.
- Metadata lives on the coordinator: it's a planning SPOF (mitigate with HA on
  the coordinator itself).

**Next:** [Module 07 — Partitioning & Time-Series](07-range-and-timeseries.md)
