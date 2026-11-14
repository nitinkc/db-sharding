# Module 04 — Choosing a Shard Key

The distribution column is a one-way door. `undistribute_table` +
`create_distributed_table` will move you, but on a real dataset that's a
migration. Evaluate candidates against five criteria:

## The five criteria

| Criterion | Question | bazaar example |
|---|---|---|
| Cardinality | Enough distinct values to fill every shard? | `seller_id` ✓ (10k→10M); `country` ✗ (5) |
| Uniformity | Do values spread load evenly? | `seller_id` ✓; `country` puts 60% in one shard |
| Query alignment | Do dominant queries filter on it? | "this seller's listings" filters `seller_id` ✓ |
| Co-location potential | Do related tables share it? | sellers/listings/favorites all carry `seller_id` |
| Immutability | Does the value ever change? | ids never change; a `status` column would |

The ideal shard key is **a column that appears in most of your queries AND
splits data evenly**. When those pull in opposite directions, query alignment
usually wins — a slightly uneven single-shard query beats an even fan-out.

## Primary keys must contain the shard key

Citus enforces: every `UNIQUE`, `PRIMARY KEY`, or foreign-key constraint on a
distributed table must **include the distribution column**. That's why
`listings` is keyed `(seller_id, listing_id)` and `sellers_by_country` is keyed
`(country, seller_id)` — uniqueness can only be checked inside a shard without
a cluster-wide lock.

## Shard key immutability

`UPDATE` on the distribution column is refused:
`ERROR: modifying the partition value of rows is not allowed`. The update is
really a row *move* between shards — possibly across machines. Citus makes you
say so explicitly: `INSERT` the new row + `DELETE` the old in one transaction
(Lab 6, Task 7). Design consequence: **never shard on a mutable attribute**.

## How many shards?

- Too few ⇒ coarse rebalancing, big shards.
- Too many ⇒ metadata and per-shard-query overhead.
- Citus default is 32; this course uses **8** so two workers get a visible 4/4
  split. Pick a number ≥ expected max nodes so rebalancing (not resharding)
  absorbs growth.

## Rebalancing vs resharding

- **Rebalancing** (`rebalance_table_shards()`): move existing shards between
  workers. Online, cheap-ish — fixes *placement* imbalance.
- **Resharding** (change shard count or key): rewrites every row's placement —
  fixes a *design* mistake, expensively.

Co-location ties related tables to one shard count, so rebalance them together
via the colocation group.

## Anti-patterns

- Shard key with one dominant value (a `country='US'` shard). → hotspot.
- Monotonic range key on an append-only stream. → write hotspot.
- Low-cardinality enum (`status`, `type`, `country`). → empty shards + skew.
- Key absent from the hot queries. → permanent fan-out.

![Hashing seller IDs into shards placed across worker nodes](../diagrams/hash-placement.svg)

**Next:** [Module 05 — Query Routing](05-query-routing.md)
