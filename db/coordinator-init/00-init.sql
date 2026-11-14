-- bazaar coordinator initialisation: extension, schema, seed data.
-- Workers are registered afterwards by scripts/bootstrap.sh.

CREATE EXTENSION IF NOT EXISTS citus;

-- ---------------------------------------------------------------------------
-- sellers: one row per seller profile (10,000 rows)
-- ---------------------------------------------------------------------------
CREATE TABLE sellers (
    seller_id    bigint PRIMARY KEY,
    store_name   text NOT NULL,
    display_name text NOT NULL
);

INSERT INTO sellers (seller_id, store_name, display_name)
VALUES
    (1, 'leather_lane',   'Leather Lane'),
    (2, 'copper_kettle',  'Copper Kettle'),
    (3, 'maple_and_pine', 'Maple & Pine');

INSERT INTO sellers (seller_id, store_name, display_name)
SELECT g, 'store_' || g, 'Seller ' || g
FROM generate_series(4, 10000) AS g;

-- ---------------------------------------------------------------------------
-- listings: one row per product listing (~3 per seller, 30,000 rows)
-- ---------------------------------------------------------------------------
CREATE TABLE listings (
    seller_id  bigint NOT NULL,
    listing_id bigint NOT NULL,
    title      text NOT NULL,
    price      numeric(10,2) NOT NULL,
    PRIMARY KEY (seller_id, listing_id)
);

INSERT INTO listings (seller_id, listing_id, title, price)
SELECT s.seller_id, l, 'Item ' || l || ' from store ' || s.seller_id,
       ((s.seller_id * 7 + l * 13) % 500 + 1)::numeric(10,2)
FROM sellers s, generate_series(1, 3) AS l;

-- ---------------------------------------------------------------------------
-- favorites: one row per buyer favorite (~5 per seller, 50,000 rows)
-- seller_id is the seller of the favorited listing
-- ---------------------------------------------------------------------------
CREATE TABLE favorites (
    seller_id  bigint NOT NULL,
    listing_id bigint NOT NULL,
    buyer_id   bigint NOT NULL
);

INSERT INTO favorites (seller_id, listing_id, buyer_id)
SELECT s.seller_id, (f % 3) + 1, (s.seller_id * 31 + f * 17) % 10000 + 1
FROM sellers s, generate_series(1, 5) AS f;

-- ---------------------------------------------------------------------------
-- sellers_by_country: one row per seller, distributed by country (8 shards).
-- Deliberately skewed: 'US' holds ~60% of rows so learners can observe what a
-- low-cardinality shard key does to data spread.
-- ---------------------------------------------------------------------------
-- NOTE: the primary key must include the distribution column (country) — a
-- Citus rule the course covers in module 04.
CREATE TABLE sellers_by_country (
    seller_id  bigint NOT NULL,
    store_name text NOT NULL,
    country    text NOT NULL,
    PRIMARY KEY (country, seller_id)
);

INSERT INTO sellers_by_country (seller_id, store_name, country)
SELECT s.seller_id, s.store_name,
       CASE
           WHEN s.seller_id <= 6000 THEN 'US'
           WHEN s.seller_id <= 7500 THEN 'GB'
           WHEN s.seller_id <= 8500 THEN 'DE'
           WHEN s.seller_id <= 9500 THEN 'IN'
           ELSE 'BR'
       END
FROM sellers s;

-- NOTE: sellers_by_country is distributed by scripts/bootstrap.sh, after the
-- worker nodes are registered. Distributing it here would place all shards on
-- the coordinator.
