# Module 06 — Resharding, Rebalancing, and the Limits

## Adding a node

```sql
SELECT citus_add_node('worker4', 5432);
SELECT rebalance_table_shards();
```

The new worker starts empty. The rebalancer moves shard *placements* until each
node holds a fair share — our 8-shard / 3-worker cluster (3, 3, 2) becomes
8-shard / 4-worker: 2, 2, 2, 2. Logical shards don't change; only which node
hosts them moves. Queries keep working during the move (metadata flips at the
end).

## Rebalancing ≠ resharding

| | Rebalance | Reshard / redistribute |
|---|---|---|
| What changes | Which *node* hosts each shard | Number of shards, or the shard key itself |
| Trigger | `citus_add_node` + `rebalance_table_shards()` | `undistribute_table` + `create_distributed_table` |
| Data moved | Whole shards (cheap per row) | Every row re-routed (expensive) |
| When | Cluster grows; skew drift | Wrong initial design |

This is why shard count and shard key are front-loaded decisions (Module 04).

## Tenant isolation

A "mega-fleet" (a national postal carrier running 100k vehicles on one
`fleet_id`) can overload one shard even under a good key. Citus offers tenant
isolation (`isolate_tenant_to_new_shard`) — split that tenant onto its own
shard so the noisy neighbor stops hurting others. The general concept exists
in every sharded system as *shard splitting* or *dedicated shards*.

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
  has the whole table (Lab 8 uses this for geofences).
- Metadata lives on the coordinator: it's a planning SPOF (mitigate with HA on
  the coordinator itself).

## Quick check

<quiz>
You add a worker and run `rebalance_table_shards()`. What changes?
- [ ] The number of shards increases
- [ ] Every row is re-routed through the shard-key hash
- [x] Whole shards move to the new node; shard count and key are unchanged
- [ ] The table is undistributed and recreated

Rebalancing moves *placements*, not rows — cheap per row. Changing the shard count or key is *resharding*: every row gets re-routed.
</quiz>

<quiz>
A mega-fleet overloads one shard even under a good shard key. What does Citus offer?
- [x] Tenant isolation — split that tenant onto its own dedicated shard
- [ ] Convert the table to a reference table
- [ ] Increase the replication factor
- [ ] Nothing — hotspots are unavoidable

`isolate_tenant_to_new_shard` gives the noisy neighbor a dedicated shard; the general pattern is shard splitting.
</quiz>

**Next:** [Module 07 — Partitioning & Time-Series](07-range-and-timeseries.md)
