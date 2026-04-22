---
id: cpt-ingestion-adr-mariadb-migration-runner
status: accepted
date: 2026-04-21
---

# ADR-0004 — MariaDB migration runner

## Context

The project uses MariaDB as the transactional store for backend-facing,
operator-editable data (the first consumer is the `persons` table — see
`cpt-insightspec-ir-dbtable-persons-mariadb`). MariaDB is a long-lived
schema whose DDL will evolve over time (new tables, columns, indexes,
data backfills).

ClickHouse already has a file-based migration mechanism (`src/ingestion/
scripts/migrations/*.sql`, looped inline in `init.sh`). It relies on
`CREATE ... IF NOT EXISTS` guards inside each migration — there is no
`schema_migrations` bookkeeping table. This is acceptable for an analytics
store where almost all migrations are idempotent `CREATE` statements, but
it is a weak foundation for MariaDB where we expect `ALTER TABLE`, data
backfills, and mixed SQL + shell migrations.

The initial `persons` DDL was applied inline from `seed-persons.sh`, which
conflated two responsibilities: **schema migration** (one-way, applies
once, never rolls back) and **data seed** (one-time bootstrap of existing
rows from `identity.identity_inputs`). That conflation is wrong — the
seed is explicitly one-shot and lives outside the migration history; the
DDL belongs under a migration runner along with every future DDL change.

## Decision

We introduce a **dedicated MariaDB migration runner** with the following
contract.

### 1. Runner script

`src/ingestion/scripts/run-migrations-mariadb.sh` — stand-alone runner,
not shared with ClickHouse. ClickHouse migrations keep their existing
inline loop in `init.sh` untouched.

### 2. Directory layout

```
src/ingestion/scripts/migrations/
    *.sql                       # ClickHouse migrations (existing, unchanged)
    mariadb/
        YYYYMMDDHHMMSS_<name>.sql   # SQL migration
        YYYYMMDDHHMMSS_<name>.sh    # shell migration
```

One flat directory per target. The ClickHouse layout stays asymmetric on
purpose — minimising churn in the existing, working path.

### 3. Migration tracking: `schema_migrations` table

The runner bookkeeps applied migrations in a dedicated MariaDB table:

```sql
CREATE TABLE IF NOT EXISTS schema_migrations (
    version     VARCHAR(255) NOT NULL PRIMARY KEY,
    applied_at  DATETIME(3)  NOT NULL DEFAULT CURRENT_TIMESTAMP(3)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
```

The runner creates this table on its first invocation (no zero-migration
file is used).

**`version`** = the full filename without extension
(e.g. `20260421000000_persons` for `20260421000000_persons.sql`). Chosen
over the bare timestamp prefix to remain unambiguous if two migrations
share a timestamp (rare but possible) and to make `schema_migrations`
rows self-describing when read by a human.

### 4. Execution rules

1. Load the set of already-applied versions from `schema_migrations`.
2. Enumerate every `*.sql` and `*.sh` file in `migrations/mariadb/`,
   sort lexicographically — the `YYYYMMDDHHMMSS_` prefix forces
   chronological order.
3. For each file whose `version` is not in the applied set:
   - `.sql` — pipe the file through `kubectl -n $MARIADB_NAMESPACE
     exec -i $MARIADB_POD -c $MARIADB_CONTAINER -- mariadb -u … -p… -D
     $MARIADB_DB --batch`. The MariaDB client lives inside the
     Bitnami MariaDB pod; the runner pipes the file through `kubectl
     exec`'s stdin.
   - `.sh` — execute the file with `bash`. The runner exports
     `MARIADB_URL`, `MARIADB_USER`, `MARIADB_PASSWORD`, `MARIADB_HOST`,
     `MARIADB_PORT`, `MARIADB_DB`, `MARIADB_NAMESPACE`, `MARIADB_POD`,
     `MARIADB_CONTAINER` to the child process. The migration may use
     any of them and may itself invoke `kubectl exec` or any other
     path to the database.
4. On success (exit code 0 for `.sh`, no SQL error for `.sql`), the
   runner inserts the version row into `schema_migrations`.
5. On failure (non-zero exit / SQL error), the runner aborts immediately
   — the partially-applied migration is **not** recorded. The operator
   fixes the migration or the state and re-runs the runner. The
   already-applied migrations before the failing one keep their rows in
   `schema_migrations` and are skipped on the next run.

### 5. Idempotency in two layers

The runner prevents re-execution via `schema_migrations`. Migrations
themselves **should still be written idempotently** (`CREATE TABLE IF
NOT EXISTS`, `ALTER TABLE … ADD COLUMN IF NOT EXISTS`, `INSERT IGNORE`,
etc.). If an operator manually drops `schema_migrations` or the table
itself, the runner must still be able to re-run without crashing.

### 6. Invocation

The runner is invoked automatically from `init.sh` after the ClickHouse
migration loop and before connector registration. Explicit manual
invocation (`./scripts/run-migrations-mariadb.sh`) is also supported
for targeted development.

### 7. Separation from one-shot seeds

One-time data seeds (e.g. `scripts/seed-persons.sh`) are **not**
migrations. They run exactly when an operator chooses to bootstrap a
table from existing data and are re-runnable only by virtue of their own
idempotency machinery (see ADR-0002 for the `persons` seed design).
They are stored as top-level scripts, not under `migrations/mariadb/`.

Specifically, `seed-persons.sh` stops applying the `persons` DDL after
this ADR lands — the `persons` DDL moves under
`migrations/mariadb/20260421000000_persons.sql` and becomes the runner's
responsibility.

## Rationale

- **Why a dedicated `schema_migrations` table** (vs. the ClickHouse
  style of `IF NOT EXISTS` guards only)? MariaDB schema evolution will
  include non-idempotent data migrations (backfills, one-shot `UPDATE`s,
  re-shaping of rows). Tracking version applies cleanly to those; `IF
  NOT EXISTS` alone does not.

- **Why full filename without extension as `version`** (vs. timestamp
  prefix)? Two migrations may be authored within the same second during
  a merge conflict resolution; including the descriptive suffix makes
  every version unambiguous, and operators reading
  `schema_migrations` immediately know what was applied without
  cross-referencing filenames.

- **Why SQL + SH in one directory** (vs. two sub-directories)? Schema
  changes and data backfills are often chronologically interleaved (a
  column add followed by a data backfill followed by a constraint add).
  Mixing both kinds in one flat directory preserves the linear
  chronological order that the runner relies on.

- **Why a separate runner script** (vs. extending the ClickHouse loop
  in `init.sh`)? The two targets use different CLIs (`clickhouse-client`
  vs `mariadb`), different authentication, and different execution
  model (the MariaDB runner needs `schema_migrations` bookkeeping).
  A single shared runner would be branchy and fragile.

- **Why `kubectl exec` into the MariaDB pod** (vs. a local `mysql`
  client + port-forward)? The Bitnami MariaDB image ships with its
  own `mariadb` and `mysql` clients inside the pod. Going through
  `kubectl exec` eliminates two host-side dependencies (`mariadb`
  client, `nc` for port-check), removes the need for port-forward
  in the runner's control path, and works uniformly across
  Linux/macOS/Windows Git Bash. The trade-off — runner assumes a
  reachable Kind / K8s pod — matches the local-dev use-case this
  runner targets. Production DDL changes to backend-owned tables
  continue through `seaql_migrations`; if a future production
  environment uses a managed MariaDB, the runner's `kubectl exec`
  assumption is revisited then.

- **Why keep the ClickHouse asymmetry** (ClickHouse in `migrations/*.sql`,
  MariaDB in `migrations/mariadb/*.*`)? Moving ClickHouse migrations
  into `migrations/clickhouse/` is cosmetic refactoring that ripples
  through `init.sh`, docs, and muscle memory. Zero-churn asymmetry is
  cheaper than symmetry.

- **Why auto-invoke from `init.sh`** (vs. operator-driven)? `init.sh`
  already owns end-to-end post-startup bring-up. Forcing operators to
  remember an extra "now run MariaDB migrations" step invites drift
  and failed smoke tests. Symmetry with the existing ClickHouse call
  is operational clarity.

## Consequences

- **New contract for anyone adding a MariaDB table or DDL change**:
  create a new file in `src/ingestion/scripts/migrations/mariadb/`
  with the `YYYYMMDDHHMMSS_description.{sql,sh}` pattern. Do not edit
  existing migration files after they have been applied in any shared
  environment — write a follow-up migration.

- **Data seeds remain explicit one-shot scripts** outside the runner.
  `seed-persons.sh` becomes a pure seed (no DDL) and stays at
  `src/ingestion/scripts/seed-persons.sh`.

- **`schema_migrations` is itself part of the MariaDB schema** but is
  not created by a migration file — it is created by the runner. This
  is a deliberate small bootstrap asymmetry: the mechanism that tracks
  migrations must exist before the first migration runs.

- **SH migration authors must treat their script as one-shot**. Unlike
  a `seed` script, an SH migration runs once across the life of the
  environment. If it fails mid-way, the author is responsible for
  making the rest of it re-runnable or for cleaning the partial state
  manually.

- **The runner is fail-stop, not fail-continue**. A broken migration
  halts the pipeline. This is intentional — applying subsequent
  migrations on top of a broken earlier state is unsafe.

## Alternatives considered

- **No `schema_migrations` table, rely on `IF NOT EXISTS` idempotency
  only** (the current ClickHouse approach). Rejected: does not cover
  data migrations or `ALTER`s; leaves operators without a "what has
  been applied?" answer.

- **Use a third-party tool** (Flyway, Liquibase, golang-migrate,
  `migrate`). Rejected: the project already has a flat file-based
  convention for ClickHouse; matching it keeps the repo
  self-contained. A 50-line bash runner is lower operational cost than
  deploying another CLI into the toolbox image.

- **Share a single runner between ClickHouse and MariaDB** via a
  `--target` flag. Rejected: see Rationale — different CLIs,
  different network access, different bookkeeping.

- **Separate directories for SQL and SH** (`migrations/mariadb/sql/`
  and `migrations/mariadb/sh/`). Rejected: breaks the linear
  chronological ordering when a SQL DDL and a SH backfill are
  related.

- **Put the ClickHouse directory under `migrations/clickhouse/` for
  symmetry**. Rejected: cost (ripples through init.sh, docs, every
  operator's muscle memory) exceeds benefit (cosmetic).

- **Include seed scripts under `migrations/mariadb/` as SH files**.
  Rejected: seeds are one-shot data bootstraps that read from
  external systems (ClickHouse) and belong in the operator's
  bring-up playbook, not in the permanent schema history of the
  database. Mixing them would make "what is this environment's
  schema state?" ambiguous.

## Related

- [ADR-0005](0005-coexist-with-seaql-migrations.md) — coexistence with
  the SeaORM `seaql_migrations` tracker in the same `analytics`
  database (ownership split, table-to-tracker rules)
- `src/ingestion/scripts/run-migrations-mariadb.sh` — the runner
- `src/ingestion/scripts/migrations/mariadb/` — migration files
- `src/ingestion/scripts/init.sh` — invoker
- `cpt-insightspec-ir-dbtable-persons-mariadb` — first MariaDB table
- `docs/domain/identity-resolution/specs/ADR/0002-deterministic-person-id-for-seed.md`
  — the `persons` one-shot seed (separate mechanism)
- `docs/domain/ingestion/specs/DESIGN.md` §4.2 "Startup scripts" —
  operator playbook
