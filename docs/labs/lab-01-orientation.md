# Lab 1 — Orientation: Meet the Cluster

**Module reference:** [Module 03 — Citus Architecture](../modules/03-citus-architecture.md)

## Goal

Get connected to the cluster and learn the two facts every sharded system starts
with: *what software am I running?* and *how many nodes do I have?*

## Terms you will encounter

```
                 psql
                   |
                   |  You connect here
                   v
        +---------------------+
        |     COORDINATOR     |
        |   localhost:5432    |
        +----------+----------+
                   |
                   v
        +---------------------+
        |   WORKER NODE(S)    |
        +---------------------+
```

![Citus cluster showing the coordinator and worker nodes](../diagrams/citus-cluster-architecture.svg)

| Term | Meaning |
|---|---|
| Coordinator | The Citus node you connect to. Applications send queries to the coordinator, which forwards them to the appropriate workers and merges the results. |
| Worker | A node that stores shards and executes the queries the coordinator delegates to it — one worker per shard, or many in parallel. |
| Distributed table | A table that looks ordinary to SQL, but whose rows live in shards spread across the workers. |
| Shard | One slice of a distributed table, stored on a worker. |
| Distribution column | The column Citus uses to decide which shard a row belongs to. The same value always maps to the same shard. Also called the *shard key*. |
| Shard placement | The assignment of a shard to the worker that stores it. |

## Connect

```
psql -h localhost -p 5432 -U postgres -d bazaar
```

(No password — this is a local, throwaway lab cluster.)

If you don't have `psql` installed locally, use the coordinator container:

```
docker exec -it bazaar-coordinator psql -U postgres -d bazaar
```

## Task 1.1 — Check the Citus version

Determine whether the Citus extension is installed in the `bazaar` database and
identify its version.

<details><summary>Hint</summary>

Citus is a PostgreSQL *extension*. PostgreSQL tracks installed extensions in
`pg_extension` (columns: `extname`, `extversion`). You can also see it with the
`\dx` meta-command.

</details>

**Question:** What is the version of the Citus extension installed in `bazaar`?

## Task 1.2 — Count the active workers

The coordinator keeps a registry of every worker node in the cluster. Find out
how many worker nodes are **active** — registered *and* reachable.

<details><summary>Hint</summary>

Citus ships a helper function `citus_get_active_worker_nodes()` that returns
one row per active worker (`node_name`, `node_port`). The raw metadata lives in
`pg_dist_node` if you want to look deeper.

</details>

**Question:** How many active worker nodes does the coordinator report?

## Checkpoint

Before moving on, be able to answer:

- [ ] What is the coordinator's job when a query arrives?
- [ ] Which two pieces of metadata did you just query (extension registry and node registry)?

**Next:** [Lab 2 — How is the `sellers` table stored?](lab-02-table-storage.md)

*Stuck? Compare your queries with [solutions/lab-01-solutions.md](../solutions/lab-01-solutions.md).*
