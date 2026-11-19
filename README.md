# Database Sharding — A Hands-On Course

Learn database sharding with a real four-node Citus cluster, a seeded fleet
telematics and geofencing platform (PostGIS), theory modules, guided labs, and
inline diagrams.

## Documentation

All course content lives under [`docs/`](docs/index.md):

- [Course overview and syllabus](docs/index.md)
- [Environment setup](docs/modules/00-environment-setup.md)
- [Lab 1 — Orientation](docs/labs/lab-01-orientation.md)
- [Lab solutions](docs/solutions/)

Preview the searchable MkDocs Material site with [uv](https://docs.astral.sh/uv/):

```bash
uv sync --locked
uv run mkdocs serve
```

Build and validate the static site:

```bash
uv run mkdocs build --strict
```

## Start the lab cluster

Requires Docker Desktop. Run these commands from the repository root:

```bash
./scripts/bootstrap.sh
psql -h localhost -p 5432 -U postgres -d fleet
```

Without local `psql`, use `docker exec -it fleet-coordinator psql -U postgres -d fleet`.
The no-password configuration is only for this local lab.

## Repository layout

```text
docs/
  index.md                 course overview and syllabus
  modules/                 theory modules (00–08)
  labs/                    guided exercises
  solutions/               answer keys and expected output
  diagrams/                SVG images and editable draw.io sources
db/
  Dockerfile               postgres:16 + Citus 13.4 + PostGIS (multi-arch)
  coordinator-init/        schema and seed data (first boot only)
  worker-init/             worker extension setup
scripts/                   cluster bootstrap and reset commands
docker-compose.yml         local four-node Citus cluster
mkdocs.yml                 documentation site configuration
pyproject.toml             documentation dependencies managed by uv
```
