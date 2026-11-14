# Module 08 — Capstone: Design the Orders Workload

Apply everything. No guided steps — you make the calls and defend them with
evidence from the cluster.

## Scenario

Bazaar launches checkout. Two new tables:

```sql
CREATE TABLE orders (
  seller_id  bigint NOT NULL,
  order_id   bigint NOT NULL,
  buyer_id   bigint NOT NULL,
  total      numeric(10,2) NOT NULL,
  status     text NOT NULL DEFAULT 'paid',
  created_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (seller_id, order_id)
);

CREATE TABLE order_items (
  seller_id  bigint NOT NULL,
  order_id   bigint NOT NULL,
  listing_id bigint NOT NULL,
  quantity   int NOT NULL,
  PRIMARY KEY (seller_id, order_id, listing_id)
);

INSERT INTO orders (seller_id, order_id, buyer_id, total)
SELECT s.seller_id, o, (s.seller_id * 13 + o) % 10000 + 1,
       ((s.seller_id + o) % 300 + 20)::numeric(10,2)
FROM sellers s, generate_series(1,4) AS o;          -- 40,000 orders

INSERT INTO order_items
SELECT o.seller_id, o.order_id, (o.order_id % 3) + 1, (o.order_id % 5) + 1
FROM orders o;                                       -- 40,000 items
```

Run the DDL + seed on the coordinator first (they're local tables).

## Dominant queries (given by product)

1. `SELECT * FROM orders WHERE seller_id = ?` — storefront order history
   (highest traffic).
2. `SELECT * FROM orders o JOIN order_items i USING (seller_id, order_id)
    WHERE o.seller_id = ?` — order detail page.
3. Weekly revenue report:
   `SELECT date_trunc('week', created_at) w, sum(total) FROM orders GROUP BY 1`
   (run by finance, off-hours).

## Your tasks

1. **Choose a distribution column for `orders`** and justify it against the
   five criteria (cardinality, uniformity, query alignment, co-location,
   immutability). Note the PK constraint implications.
2. **Distribute `orders` and `order_items`** with co-location that serves
   query 2 optimally.
3. **Prove it:** `EXPLAIN (COSTS OFF)` queries 1 and 2 for `seller_id = 1` and
   `seller_id = 7`. Record `Task Count` for each.
4. **Analyze the trade-off:** what does query 3 (no `seller_id` filter) cost
   under your design? Could a different design serve it better — and what would
   it cost queries 1–2?
5. **Break something:** try `UPDATE orders SET seller_id = seller_id + 100000
   WHERE seller_id = 1`. Explain the error and fix the design constraint it
   reveals.
6. **Simulate growth:** `SELECT citus_add_node(...)` can't add a 3rd worker
   (only two exist) — instead, reason it through: after adding `worker3`, how
   would your 8 shards redistribute, and which Citus command does it?

## Self-check rubric

- [ ] `orders` and `order_items` share a `colocation_id` with `sellers` (or you
      can defend a different grouping).
- [ ] Query 1 and query 2 both plan as `Task Count: 1`.
- [ ] You can state why query 3 fans out — and that it's acceptable here
      (off-hours batch) rather than a design error.
- [ ] You predicted the Task-5 error before running it.
- [ ] You named `rebalance_table_shards()` for task 6 and predicted a 3/3/2
      (or 4/4/0 → 3/3/2) placement split.

## Stretch goals

- Extend [Lab 6's partitioning investigation](../labs/lab-06-shard-key-lab.md#task-83-connect-partitions-to-the-shard-investigation)
  into a design for time-partitioned `orders`. Plan it separately before changing
  the working capstone tables: retain seller distribution, choose bounded monthly
  ranges, and compare seller-only, time-only, and seller-plus-time queries.
  Explain which layer prunes partitions and which routes worker tasks.
- Identify how partitioning `orders` on `created_at` changes the existing
  `(seller_id, order_id)` primary key: a native partitioned-parent key must also
  include the time key. Explain the consequences for `order_items`, whose current
  schema has no order timestamp, and propose a compatible key/join design rather
  than assuming the original constraints work unchanged.
- Write a retention plan for an expired month, including how archiving differs
  from deleting and how related order items stay consistent. No destructive
  retention operations are required for the capstone.
- Make `countries` a reference table (`create_reference_table`) and explain
  when that beats distributing it.
- Design a `buyer_id`-sharded alternative. What queries get faster, which get
  catastrophic, and why did the seller-side key still win?

*This capstone has no single right answer — the rubric rewards designs whose
evidence (EXPLAIN output, metadata queries) supports the stated trade-offs.*
