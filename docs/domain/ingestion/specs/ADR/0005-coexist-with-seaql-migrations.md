---
id: cpt-ingestion-adr-coexist-seaql-migrations
status: accepted
date: 2026-04-22
---

# ADR-0005 — Coexistence with SeaORM's `seaql_migrations` in the same MariaDB

## Context

`src/backend/services/analytics-api` (Rust, SeaORM) already manages its
own schema inside MariaDB `analytics` via SeaORM's built-in migration
machinery:

- Tracker table: `seaql_migrations(version VARCHAR(255) PK,
  applied_at BIGINT)` — unix-timestamp flavour, not DATETIME.
- Migrations authored as Rust modules in
  `src/backend/services/analytics-api/src/migration/m{YYYYMMDD}_{seq}_{name}.rs`
  using SeaORM's code-first DSL (`Table::create()`, `ColumnDef::new()`,
  `create_index()`, etc.) and registered in `migration/mod.rs`.
- Applied automatically on service startup via `Migrator::up(db, None)`
  in `infra/db/mod.rs` — schema evolves together with the service
  binary.
- Currently owns tables `metrics`, `thresholds`, `table_columns`, plus
  seed rows in `metrics`.

This was already in place before ADR-0004 introduced the MariaDB
migration runner for ingestion/identity/person DDL. The obvious
question: reuse SeaORM's tracker, or add a second, independent one?

This ADR records the decision to **coexist** — run both migration
trackers in the same database, under separate ownership.

## Decision

### 1. Two independent migration trackers in `analytics` DB

| Tracker | Owner | Author in | Triggered by | Format |
|---|---|---|---|---|
| `seaql_migrations` | `analytics-api` backend (SeaORM) | Rust modules with `MigrationTrait` | `Migrator::up()` at service startup | code-first DSL |
| `schema_migrations` | ingestion/identity/person/org-chart (and any future non-backend domain) | `.sql` / `.sh` files | `run-migrations-mariadb.sh` (from `init.sh`) | SQL files and shell scripts |

The two trackers **never reference each other**. They are separate
tables in the same database; the `version` namespaces are distinct by
construction (SeaORM uses `m{YYYYMMDD}_{seq}_{name}`, our runner uses
`{YYYYMMDDHHMMSS}_{name}`).

### 2. Single shared `schema_migrations` for all non-backend domains

Identity-resolution, person, org-chart, and any other domain that owns
a MariaDB table goes through **the same** `schema_migrations` tracker
and **the same** `scripts/migrations/mariadb/` directory. There is **no**
`identity_migrations` / `person_migrations` split.

Rationale:
- Migration trackers align with **tooling boundaries**, not domain
  boundaries. We have one runner, one invocation from `init.sh`, one
  history of applied versions — one tracker matches that shape.
- Per-domain trackers would multiply runners, invocations, and history
  tables for no operational gain. "Which trackers are applied?" has
  one answer (`schema_migrations`) instead of N.
- Domain ownership of each **table** is recorded in the domain's spec
  (identity-resolution/DESIGN.md for `persons`, etc.), not in the
  migration tracker. The tracker is an infra artifact.

### 3. Table ownership rule

A new MariaDB table is registered under the tracker owned by the
**domain that specifies the table**:

| Table spec domain | Tracker |
|---|---|
| `analytics-api` backend (`metrics`, `thresholds`, `table_columns`) | `seaql_migrations` |
| identity-resolution (`persons`, future `aliases`-mirror if any) | `schema_migrations` |
| person domain (if any MariaDB-backed tables emerge) | `schema_migrations` |
| org-chart domain (if any MariaDB-backed tables emerge) | `schema_migrations` |
| ingestion (internal tooling tables if any) | `schema_migrations` |

If a domain needs a backend API surface (CRUD, Rust types, SeaORM
entities) on top of one of its tables, it **still** owns the schema
via `schema_migrations` — the Rust service reads/writes pre-existing
tables rather than migrating them. Two rules keep this workable:

1. `analytics-api` (or any other Rust service reading `schema_migrations`-
   owned tables) **must not** add them to its SeaORM `Migrator` —
   otherwise we get two `CREATE TABLE` attempts competing for the same
   name.
2. SeaORM entity definitions (`entities.rs`) for `schema_migrations`-
   owned tables **must match** the DDL in
   `scripts/migrations/mariadb/*.sql`. Drift is caught at runtime as
   SQL errors; there is no compile-time link.

### 4. Lifecycle ordering

`./init.sh` applies migrations in this order:

1. ClickHouse migrations (inline loop, existing).
2. `schema_migrations` — our runner, `run-migrations-mariadb.sh` —
   **before** any Rust service starts.
3. Connector registration + connections.

`seaql_migrations` applies at service startup — i.e. **after** step 2.
This is the critical guarantee: if a SeaORM service reads a table
owned by `schema_migrations` (future case), that table already exists
by the time SeaORM starts.

## Rationale

### Why not reuse `seaql_migrations`

- **Ownership mismatch.** `seaql_migrations` is the internal schema
  tracker of *one service*. `persons` is an identity-resolution
  domain table (see spec `cpt-insightspec-ir-dbtable-persons-mariadb`),
  not an analytics-api concern. Adding the `persons` migration to
  the `analytics-api` SeaORM `Migrator` would make analytics-api the
  apparent owner of a table it does not spec.
- **Authoring mismatch.** SeaORM migrations are Rust code, compiled
  into the service binary. Every DDL change to a `schema_migrations`-
  owned table would require a backend Rust rebuild — artificial
  friction and a cross-team dependency for ingestion/identity
  engineers.
- **Lifecycle mismatch.** SeaORM runs migrations at **service startup**.
  Our tables must exist **before** services start (Rust services read
  them, workflows populate them). `./init.sh` is the correct moment;
  `Migrator::up()` at binary start is not.
- **Format mismatch.** SeaORM supports code-first DSL only. Shell
  migrations (for `.sh`-driven data backfills — see ADR-0004) have
  no place in `MigrationTrait`.

### Why coexistence is safe and standard

Multiple migration trackers in one database is a common pattern:
- Django apps each carry their own `django_migrations` scope.
- Flask-Migrate / Alembic projects share a database with Django or
  with native SQL migrations managed by ops.
- ActiveRecord's `schema_migrations` coexists with DBA-owned
  `ops_migrations` or Flyway's `flyway_schema_history`.

The only coordination requirement is **name disambiguation** (handled
by the distinct tracker table names and distinct version formats) and
**ownership clarity per table** (handled by §3).

### Why a single `schema_migrations` for all non-backend domains (not
per-domain)

Considered split into `identity_migrations`, `person_migrations`,
`org_chart_migrations`. Rejected: each split adds a tracker table,
a migration directory, a runner invocation in `init.sh`, and a
mental model ("which tracker does this table belong to?"). The
unifying trait of all these migrations is "applied by
`./init.sh`-era tooling" — one tracker expresses that cleanly.

## Consequences

- **`init.sh` bring-up sequence is now fixed:** ClickHouse migrations
  → `schema_migrations` via our runner → Rust services start (SeaORM
  applies `seaql_migrations`) → connectors + connections. Out-of-
  order startup breaks the "tables exist before readers" invariant
  for `schema_migrations`-owned tables read by Rust services.

- **`schema_migrations` is authoritative for non-backend DDL.**
  Authors of identity-resolution / person / org-chart MariaDB tables
  add files to `scripts/migrations/mariadb/`, not to the backend's
  Rust `Migrator`. If a Rust service needs SeaORM entity types for
  one of those tables, it defines the entity manually (not via
  `Migrator`) and keeps it in sync.

- **Drift detection is runtime-only.** There is no compile-time check
  that a SeaORM entity matches a SQL-migrated table. Schema drift
  surfaces as runtime `SqlError` when SeaORM queries a column that
  does not exist (or has wrong type). Acceptable trade-off for clear
  ownership.

- **No cross-tracker dependencies.** Migrations under
  `schema_migrations` must not `ALTER` or `DROP` tables owned by
  `seaql_migrations`, and vice versa. If a cross-table change is
  actually needed (e.g. a foreign key from `persons` to `metrics`),
  it must be coordinated via spec change and authored on the side of
  the child table's owning tracker.

- **Adding a new domain with MariaDB needs:** (a) a new file in
  `scripts/migrations/mariadb/` under the existing `schema_migrations`
  tracker, (b) an entry in the domain's own DESIGN.md under "Tables"
  pointing at that migration file. No new tracker, no new runner.

## Alternatives considered

- **Reuse `seaql_migrations` directly** — rejected: ownership,
  authoring, and lifecycle mismatches as detailed above.

- **Per-domain tracker tables** (`identity_migrations`,
  `person_migrations`, …) — rejected: multiplies infra without
  solving a real problem. Domain ownership of tables is documented in
  specs, not in tracker names.

- **Merge analytics-api's DDL into our bash runner** (drop SeaORM
  migrations, author `metrics`/`thresholds`/`table_columns` as SQL) —
  rejected: backend team owns that schema and relies on SeaORM's
  code-first DSL for refactor safety, type derivation, and
  `Migrator::up()` at service start. Taking it over would block
  their workflow for no architectural gain.

- **Raw SQL migrations inside `seaql_migrations`** (via
  `manager.get_connection().execute_unprepared(sql)`) — rejected:
  still requires Rust rebuild for each migration, still applies at
  service startup rather than init-time, still imposes SeaORM as a
  dependency on ingestion/identity engineers who have no other
  reason to build backend code.

## Related

- [ADR-0004](0004-mariadb-migration-runner.md) — the MariaDB migration
  runner itself (architecture, file layout, bookkeeping rules)
- `src/backend/services/analytics-api/src/migration/mod.rs` — SeaORM
  `Migrator` (reference, not modified by this ADR)
- `docs/components/backend/specs/DESIGN.md` — backend architecture
  (reference)
- `cpt-insightspec-ir-dbtable-persons-mariadb` — first table authored
  under `schema_migrations`
