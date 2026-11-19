# Module 00 — Environment Setup

Everything in this course runs against a real 4-node Citus cluster on your
machine. This module gets it running.

## Prerequisites

| Tool | Why | Check |
| --- | --- | --- |
| Docker Desktop (or Docker Engine + Compose v2) | Runs the coordinator and worker containers | `docker compose version` |
| `psql` (PostgreSQL client) — optional | Connect from your host | `psql --version` |

No local `psql`? Every lab also works via
`docker exec -it fleet-coordinator psql -U postgres -d fleet`.

> **Apple Silicon note:** the base image is `postgres:16`, which is multi-arch,
> so the cluster builds and runs as **native arm64** — no emulation, no
> platform warnings. The first `docker compose build` downloads the Citus and
> PostGIS packages; everything after that is cached.

## Start the cluster

```bash
./scripts/bootstrap.sh
```

The script:

1. `docker compose up -d` — builds `db/Dockerfile` (`postgres:16` + Citus 13.4
   from packagecloud + PostGIS 3 from PGDG, as `db-sharding-pg16-citus:13.4-postgis`)
   and starts `fleet-coordinator` (published on `localhost:5432`),
   `fleet-worker1` (`localhost:5433`), `fleet-worker2` (`localhost:5434`),
   `fleet-worker3` (`localhost:5435`). The
   stock postgres image doesn't preload Citus, so compose passes
   `-c shared_preload_libraries=citus` on all three services.
   > **Build-time network note:** the Citus package lives on
   > `packagecloud.io`, which some corporate proxies block. If the apt step
   > fails, run the build off-VPN or allowlist the host.
2. Waits for all three to pass `pg_isready`.
3. Registers all three workers with the coordinator (`citus_add_node`) — Citus cannot
   do this inside `docker-entrypoint-initdb.d`, which is why it's a script step.
4. Prints the connect string.

That's it — the script deliberately **shards nothing**. Every table starts as a
local table on the coordinator, and the labs distribute them one by one so you
can observe each change.

## Connect

```bash
psql -h localhost -p 5432 -U postgres -d fleet
```

No password — `POSTGRES_HOST_AUTH_METHOD=trust` is set for this **local,
throwaway lab environment only**. Never use `trust` for a real deployment.

## Connect with a GUI (DBeaver, TablePlus, …)

All four nodes are reachable from your host, so you can browse the coordinator
and all three workers side by side. In DBeaver: **Database → New Database
Connection → PostgreSQL**, once per node:

| Connection name | Host | Port | Database | User | Password |
| --- | --- | --- | --- | --- | --- |
| fleet-coordinator | `localhost` | `5432` | `fleet` | `postgres` | *(empty)* |
| fleet-worker1 | `localhost` | `5433` | `fleet` | `postgres` | *(empty)* |
| fleet-worker2 | `localhost` | `5434` | `fleet` | `postgres` | *(empty)* |
| fleet-worker3 | `localhost` | `5435` | `fleet` | `postgres` | *(empty)* |

Leave the password field blank (`trust` auth) and click **Test Connection** to
verify. Opening the worker connections is genuinely useful in this course:
after Lab 3 you can expand a worker's `fleet` database and *see* the actual
shard tables (`fleets_102008`, …) that Citus placed there — something the
coordinator connection alone won't show you.

## What's in the box

| Piece | Where |
| --- | --- |
| Image build | `db/Dockerfile` — `postgres:16` + `postgresql-16-citus-13.4` + `postgresql-16-postgis-3` |
| Schema + seed data | `db/coordinator-init/00-init.sql` — runs once on first `up` |
| Worker init | `db/worker-init/00-init.sql` — `CREATE EXTENSION citus` + `postgis` |
| Compose file | `docker-compose.yml` (builds `db-sharding-pg16-citus:13.4-postgis`) |
| Lifecycle scripts | `scripts/bootstrap.sh`, `scripts/reset.sh` |

The seed creates 10,000 fleets, 40,000 vehicles (each with a WGS84 GPS fix),
50,000 trips, 5 geofence polygons, and a deliberately **skewed**
`vehicles_by_region` (NA ≈ 60%) — all local tables; you'll distribute them
yourself starting in Lab 3.

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
SELECT count(*) FROM citus_get_active_worker_nodes();  -- expect 3
SELECT count(*) FROM fleets;                           -- expect 10000
SELECT postgis_version();                              -- geofencing engine is live
```

If all three work: continue to [Module 01 — Why Sharding?](01-why-sharding.md).
