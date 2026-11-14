# Module 00 — Environment Setup

Everything in this course runs against a real 3-node Citus cluster on your
machine. This module gets it running.

## Prerequisites

| Tool | Why | Check |
|---|---|---|
| Docker Desktop (or Docker Engine + Compose v2) | Runs the coordinator and worker containers | `docker compose version` |
| `psql` (PostgreSQL client) — optional | Connect from your host | `psql --version` |

No local `psql`? Every lab also works via
`docker exec -it bazaar-coordinator psql -U postgres -d bazaar`.

> **Apple Silicon note:** the `citusdata/citus` image is amd64-only, so Docker
> runs it under Rosetta/QEMU emulation. First startup is slower and you'll see a
> platform warning — that's fine.

## Start the cluster

```bash
./scripts/bootstrap.sh
```

The script:

1. `docker compose up -d` — starts `bazaar-coordinator` (published on
   `localhost:5432`), `bazaar-worker1`, `bazaar-worker2`.
2. Waits for all three to pass `pg_isready`.
3. Registers both workers with the coordinator (`citus_add_node`) — Citus cannot
   do this inside `docker-entrypoint-initdb.d`, which is why it's a script step.
4. Distributes `sellers_by_country` by `country` into 8 shards — the one table
   the course expects to be pre-distributed. (It must happen *after* step 3, or
   its shards would land on the coordinator itself.)
5. Prints the connect string.

## Connect

```bash
psql -h localhost -p 5432 -U postgres -d bazaar
```

No password — `POSTGRES_HOST_AUTH_METHOD=trust` is set for this **local,
throwaway lab environment only**. Never use `trust` for a real deployment.

## What's in the box

| Piece | Where |
|---|---|
| Schema + seed data | `db/coordinator-init/00-init.sql` — runs once on first `up` |
| Worker init | `db/worker-init/00-init.sql` — `CREATE EXTENSION citus` |
| Compose file | `docker-compose.yml` (image: `citusdata/citus:12.1`) |
| Lifecycle scripts | `scripts/bootstrap.sh`, `scripts/reset.sh` |

The seed creates 10,000 sellers, 30,000 listings, 50,000 favorites, and a
deliberately **skewed** `sellers_by_country` (US ≈ 60%) — you'll see why in
Lab 6.

## Everyday commands

```bash
docker compose ps                 # are all three up?
docker compose logs coordinator   # coordinator log
./scripts/reset.sh                # nuke everything (down -v) and rebuild fresh
```

`reset.sh` destroys **all** cluster state — including anything you created in
labs — and reseeds from scratch. Use it to restart the course cleanly.

## Sanity check

```sql
SELECT count(*) FROM citus_get_active_worker_nodes();  -- expect 2
SELECT count(*) FROM sellers;                          -- expect 10000
```

If both work: continue to [Module 01 — Why Sharding?](01-why-sharding.md).
