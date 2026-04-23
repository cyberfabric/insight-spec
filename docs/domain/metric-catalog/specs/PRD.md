# PRD — Metric Catalog

<!-- toc -->

- [Changelog](#changelog)
- [1. Overview](#1-overview)
  - [1.1 Purpose](#11-purpose)
  - [1.2 Background / Problem Statement](#12-background--problem-statement)
  - [1.3 Goals (Business Outcomes)](#13-goals-business-outcomes)
  - [1.4 Glossary](#14-glossary)
- [2. Actors](#2-actors)
  - [2.1 Human Actors](#21-human-actors)
  - [2.2 System Actors](#22-system-actors)
- [3. Operational Concept & Environment](#3-operational-concept--environment)
  - [3.1 Module-Specific Environment Constraints](#31-module-specific-environment-constraints)
- [4. Scope](#4-scope)
  - [4.1 In Scope](#41-in-scope)
  - [4.2 Out of Scope](#42-out-of-scope)
- [5. Functional Requirements](#5-functional-requirements)
  - [5.1 Catalog Storage](#51-catalog-storage)
  - [5.2 Threshold Storage and Resolution](#52-threshold-storage-and-resolution)
  - [5.3 Read API](#53-read-api)
  - [5.4 Admin Write API](#54-admin-write-api)
  - [5.5 Calculation Rules](#55-calculation-rules)
  - [5.6 Seed and Migration](#56-seed-and-migration)
- [6. Non-Functional Requirements](#6-non-functional-requirements)
  - [6.1 NFR Inclusions](#61-nfr-inclusions)
  - [6.2 NFR Exclusions](#62-nfr-exclusions)
- [7. Public Library Interfaces](#7-public-library-interfaces)
  - [7.1 Public API Surface](#71-public-api-surface)
  - [7.2 External Integration Contracts](#72-external-integration-contracts)
- [8. Use Cases](#8-use-cases)
  - [UC-001 Admin Tunes a Threshold](#uc-001-admin-tunes-a-threshold)
  - [UC-002 Product Team Adds a New Metric](#uc-002-product-team-adds-a-new-metric)
  - [UC-003 Consumer Hydrates the Catalog](#uc-003-consumer-hydrates-the-catalog)
- [9. Acceptance Criteria](#9-acceptance-criteria)
- [10. Dependencies](#10-dependencies)
- [11. Assumptions](#11-assumptions)
- [12. Risks](#12-risks)
- [13. Open Questions](#13-open-questions)

<!-- /toc -->

## Changelog

- **v1.3** (current): Extended the threshold scope model to include `team` as a first-class scope, with precedence `team + dashboard → team → dashboard → tenant → product-default`. Role-scoped overrides remain implicit — they happen through the `dashboard` scope because dashboards are already keyed by `(view_type, role)` in the Dashboard Configurator; no separate `role` scope is introduced. Team scope lands at `p2` and is gated on the Dashboard Configurator's team-lead customization feature, since without an admin path to edit team-scoped thresholds the column is just shelf-ware.
- **v1.2**: Hardened the rule↔SQL consistency story against drift. Promoted invariant-test enforcement to `p1` and reframed it as executable checks per metric (aggregation, null policy, bounds, grain). Added a forward-looking `p2` target for v2 of the catalog where simple rules compile to SQL (Tier 2 — rule becomes authoritative for a subset of metrics; DSL described in this PRD, implementation deferred). Added explicit linkage between `metric_catalog` entries and `analytics.metrics` query UUIDs — `primary_query_id` column, reverse-lookup endpoint, and a one-shot admin diagnostics endpoint that returns catalog row + thresholds + calculation rule + `query_ref` SQL for a given `metric_key`.
- **v1.1**: Expanded catalog scope to include calculation rules per metric — machine-readable declarative descriptions of how each metric is computed (aggregation function, source reference, grain, null policy, bounds). Calculation rules complement but do not replace the imperative `query_ref` SQL in `analytics.metrics`; they provide documentation, enable admin-UI "how is this calculated?" surfaces, support future validation against the SQL, and keep the door open for alternative compute backends without coupling the catalog to a specific execution engine.
- **v1.0**: Initial PRD extracted from Dashboard Configurator PRD v1.4. Metric Catalog is the single source of truth for metric metadata (label, unit, format, thresholds, source tag). It is a foundation primitive that Dashboard Configurator consumes, and that future products (alerting, reports, admin audits, scheduled digests) can also consume.

## 1. Overview

### 1.1 Purpose

Metric Catalog is a backend-owned, per-tenant registry of everything the product knows about a metric:

- **Semantic metadata** — labels, units, formats, `higher_is_better` semantics, source tags, enable flags.
- **Per-tenant thresholds** — `good` / `warn` / `alert_trigger` / `alert_bad` values for bullet-color and alert evaluation.
- **Calculation rules** — machine-readable declarative descriptions of how each metric is computed (aggregation function, source reference, grain, null policy, bounds). These do not replace the imperative `query_ref` SQL in `analytics.metrics` but complement it as documentation and validation scaffolding.

It replaces the status quo where metric metadata is duplicated between the frontend (`src/screensets/insight/api/thresholdConfig.ts` with `BULLET_DEFS`, `IC_KPI_DEFS`, and most of `METRIC_KEYS`) and backend seed migrations, and where calculation logic is implicit — readable only by people who can read ClickHouse SQL. The catalog is an independent primitive: its first consumer is Dashboard Configurator, but it is not coupled to any specific visualization surface, and calculation rules make it consumable by alerting, reports, and automated QA without re-parsing SQL.

### 1.2 Background / Problem Statement

Insight's analytics-api today stores only `analytics.metrics` (`id`, `query_ref`, `name`, `description`) and an empty `analytics.thresholds` table. Semantic metadata about each metric — the label a user reads, the unit suffix, whether higher is better, the `good`/`warn` thresholds that drive bullet color — lives on the frontend, hardcoded in TypeScript. Calculation logic — what data source drives the metric, what aggregation is applied, what null policy, what clamp — lives exclusively in ClickHouse SQL inside `query_ref`, readable only by people who can read the SQL and follow the dependency chain across gold views. Four consequences:

- **Drift**: a metric rename or a unit change requires synchronized edits in two repos; the product has already seen cases where a backend UUID added a new row without a frontend entry and the bullet rendered with generic fallbacks.
- **Per-tenant threshold tuning is impossible without a frontend deploy**: a compliance team that wants `focus_time_pct` target stricter than engineering has no path shorter than a code change.
- **Other potential consumers are blocked**: any future surface that needs to know "what does metric `cc_active` mean, what unit, what's good" — alerting rules, scheduled digests, admin audit UI — would either duplicate the metadata again or consume the current frontend file through a strange back-channel.
- **"How is this calculated?" is opaque to non-engineers**: a tenant admin tuning thresholds cannot see whether `focus_time_pct` is per-day or per-period, whether it skips nulls, whether it is clamped to 0-100, without reading SQL. Product decisions get made based on guesses about what metrics mean.

**Target Users**:

- Tenant admins tuning thresholds and labels for their organization without waiting for engineering
- Insight product team seeding default metric metadata as part of product releases
- Downstream backend services (Dashboard Configurator today; alerting and reports tomorrow) that need metadata about metrics to render or evaluate them

**Key Problems Solved**:

- No single source of truth for metric labels, units, and thresholds
- No way to override thresholds per tenant without a code deploy
- No discoverable registry of "what metrics exist and what do they mean" for tools and humans
- No way to answer "how is this metric calculated?" without reading ClickHouse SQL

### 1.3 Goals (Business Outcomes)

**Success Criteria**:

- 100% of metric metadata currently duplicated between frontend and backend resolved from a single MariaDB source (Baseline: duplicated in `thresholdConfig.ts` and Rust seed migrations; Target: backend-only by end of rollout)
- Zero frontend deploys required to change a label, unit, or threshold on existing metrics (Baseline: required for every change; Target: 0)
- Threshold changes propagate to the UI within one page load after the DB update (Baseline: not supported; Target: ≤ 5-minute cache TTL)
- 100% of active metrics carry a structured calculation rule readable by non-engineers (Baseline: 0%, only SQL exists; Target: every enabled metric has a rule by end of rollout)
- First non-dashboard consumer (e.g., an alerting rule authored against the catalog) ships without any catalog-schema change

**Capabilities**:

- Persist one row per metric with rich metadata (label, sublabel, description, unit, format, higher_is_better, is_member_scale, source tag, enable flag)
- Persist tenant-scoped threshold overrides (`good`, `warn`, `alert_trigger`, `alert_bad`)
- Persist per-metric calculation rules — structured, machine-readable, admin-viewable
- Serve the catalog to consumers via a cacheable read endpoint
- Validate metadata changes at the database and API layers (no silent corruption)

### 1.4 Glossary

| Term | Definition |
|------|------------|
| Metric | A named, quantitative measurement produced by a `metric_query` that returns rows annotated with one or more `metric_key` values. Example: `cursor_active`, `tasks_completed`, `ai_loc_share2`. |
| Metric key | Stable string identifier for a metric, used to cross-reference metadata and threshold rows. Follows `snake_case` convention. |
| Metric catalog | The MariaDB table that persists one row per `(tenant_id, metric_key)` with semantic metadata. |
| Metric threshold | A row in the threshold table that pins the `good`, `warn`, `alert_trigger`, or `alert_bad` boundary for a metric, either at tenant default scope or (optionally) at a narrower scope such as a specific dashboard. |
| Threshold scope | One of `product-default` (seeded floor), `tenant` (per-tenant default), `dashboard` (override tied to a specific dashboard UUID — also captures role because dashboards are keyed by `(view_type, role)`), `team` (override tied to a specific team, across all dashboards), or the composite `team + dashboard`. Resolution precedence, most specific wins: `team + dashboard → team → dashboard → tenant → product-default`. `tenant` is the only scope mandatory in v1; `dashboard` ships as `p2` alongside Dashboard Configurator's dashboard-scoped overrides; `team` ships as `p2` gated on Dashboard Configurator's team-lead customization feature. |
| Role-scoped override | Not a distinct scope. A threshold attached to a role-specific dashboard (e.g., `ic-backend-dev`) functions as a role-scoped override because that dashboard's key is `(view_type='ic', role='backend-dev')`. A separate `role` scope was considered and rejected to keep the precedence chain short. |
| Source tag | A short string identifying the ingestion origin of the metric (e.g., `cursor`, `jira`, `anthropic-enterprise`, `m365`, `zoom`, `slack`, `bitbucket`, `bamboohr`). Drives availability checks and connector-readiness diagnostics. |
| Calculation rule | A structured, machine-readable declarative description of how a metric is computed: aggregation function (`sum`/`avg`/`max`/`min`/`median`/`percentile`/`rate`), source view/column, grain (per-day / per-period / rolling window), null policy (preserve / skip / treat-as-zero), bounds (clamp to `[min, max]`), and for derived metrics the formula references to other metric keys or raw fields. Rules do not execute SQL — they describe what the SQL `query_ref` is supposed to do. |
| Query ref | The existing ClickHouse SQL in `analytics.metrics.query_ref`, keyed by UUID, that imperatively produces the metric's rows at query time. One `query_ref` can return multiple metric keys; the catalog stores one calculation rule per metric key to document each emitted value independently. |
| Primary query | The specific `analytics.metrics` UUID that is considered the authoritative source for a given `metric_key`. Recorded as `metric_catalog.primary_query_id` so any caller of the catalog can navigate from metric_key → query UUID → `query_ref` SQL in one hop. For the vast majority of metrics the relationship is one primary query per metric_key; rare exceptions (same metric_key emitted by multiple queries) are tracked in Open Questions. |
| Invariant test | A deterministic CI check bound to a specific metric that runs the metric's `query_ref` against a fixture dataset and asserts that behavior matches declared calculation-rule fields (aggregation function, null policy, bounds, grain). Stronger than coupling-gate heuristics; per `cpt-metric-cat-fr-invariant-tests`. |

## 2. Actors

### 2.1 Human Actors

#### Tenant Admin

**ID**: `cpt-metric-cat-actor-tenant-admin`

**Role**: Edits the tenant's metric thresholds through the admin API. Adjusts labels and descriptions via controlled interfaces when the product team allows (defaulted to read-only for metadata in v1 to avoid label drift across tenants; see Open Questions). Reads calculation rules to understand what a metric means before tuning its threshold, but does not edit rules (they are product-team-owned).

**Needs**: A view of the currently resolved catalog for their tenant including which thresholds are from tenant defaults vs scoped overrides; a human-readable rendering of each metric's calculation rule ("aggregation, source, grain, null policy"); audit trail of who changed what; preview of the effect of a threshold change before it goes live.

#### Insight Product Team

**ID**: `cpt-metric-cat-actor-product-team`

**Role**: Seeds the canonical metric catalog that every tenant starts with. Ships new metrics as part of feature releases by adding catalog entries (metadata + calculation rule) in the same PR as the new `metric_query`. Owns the calculation rule for every metric — rules evolve only through code review in a backend PR, never via admin UI. Deprecates metrics via the `is_enabled` flag.

**Needs**: Migration-based seed mechanism; a way to add a catalog entry plus its calculation rule in the same review as the metric query and frontend changes that consume it; CI gates that flag drift between `query_ref` SQL and declared calculation rules; a predictable lifecycle for deprecation.

### 2.2 System Actors

#### Analytics API

**ID**: `cpt-metric-cat-actor-analytics-api`

**Role**: Serves the catalog via `GET /catalog/metrics` with resolved per-tenant thresholds. Exposes admin CRUD for thresholds. Validates metadata integrity at the API layer.

#### Catalog Consumer

**ID**: `cpt-metric-cat-actor-consumer`

**Role**: Any backend or frontend component that reads `GET /catalog/metrics` and relies on the returned metadata. In v1 this is Dashboard Configurator; in later waves, it will include alerting, reports, scheduled digests, and the admin UI.

**Needs**: A cacheable, versioned read endpoint; stable field names across additive changes; explicit signal when a metric is disabled so consumers can degrade gracefully.

#### MariaDB Catalog

**ID**: `cpt-metric-cat-actor-mariadb`

**Role**: Persists the `metric_catalog` and `metric_threshold` tables. Provides referential integrity between thresholds and catalog entries.

## 3. Operational Concept & Environment

### 3.1 Module-Specific Environment Constraints

None beyond project defaults (Rust, Axum, SeaORM, MariaDB). The catalog inherits the analytics-api service runtime.

## 4. Scope

### 4.1 In Scope

- `metric_catalog` table: one row per `(tenant_id, metric_key)` with fields `label_i18n_key`, `sublabel_i18n_key`, `description_i18n_key`, `unit`, `format`, `higher_is_better`, `is_member_scale`, `source_tag`, `is_enabled`, `primary_query_id` (FK into `analytics.metrics.id`), timestamps
- `metric_threshold` table: per-scope threshold rows with `scope` enum (`tenant` / `dashboard` / `team`) and nullable `dashboard_id` / `team_id` references. Resolution precedence (most specific wins): `team + dashboard → team → dashboard → tenant → product-default`. `tenant` mandatory in v1; `dashboard` and `team` gated as `p2` per Dashboard Configurator PRD dependencies
- `metric_calculation` table (or equivalent JSON column on `metric_catalog`): per-metric structured calculation rule — aggregation function, source view/column, grain, null policy, bounds, formula references for derived metrics
- Executable **invariant tests** per metric — CI runs each metric's `query_ref` against a shared fixture dataset and asserts that observed behavior matches the declared calculation-rule fields (aggregation, null policy, bounds, grain). Drift between rule and SQL surfaces as a loud CI failure, not a silent documentation lie.
- `GET /catalog/metrics` read endpoint returning catalog + resolved thresholds + calculation rules + `primary_query_id` for the calling tenant
- `GET /v1/admin/metric-diagnostics/:metric_key` one-shot admin endpoint returning the full picture for a metric — catalog row + thresholds + calculation rule + primary query's `query_ref` SQL + last successful run metadata — so debugging "why does this metric look wrong" is a single call
- `GET /v1/admin/metric-queries/:query_id/metric-keys` reverse lookup returning every `metric_key` that references a given `metric_query` UUID — used by PR reviewers when a `query_ref` change touches multiple catalog entries
- `POST/PUT/DELETE /v1/admin/metric-thresholds` admin CRUD on thresholds
- Seed migration importing the current frontend metadata (`BULLET_DEFS`, `IC_KPI_DEFS`, most of `METRIC_KEYS`) as the initial catalog, setting `primary_query_id` for each entry based on the current `TEAM_BULLET_*` / `IC_BULLET_*` UUID mapping
- Seed migration authoring an initial calculation rule for every seeded metric, mirroring what the existing gold views and `query_ref` rows actually compute
- Deletion of the duplicated metadata on the frontend once the catalog endpoint is live
- Decision on the existing empty `analytics.thresholds` table (repurpose vs drop) — tracked in Open Questions, resolved in DESIGN
- Cache layer (configurable TTL, default 5 minutes) fronting `GET /catalog/metrics`

### 4.2 Out of Scope

- Admin UI for editing the catalog — deferred to a follow-up Admin-UI PRD; this PRD covers data model and API
- Tenant-level or admin-level edits of calculation rules — rules are product-team-owned and ship as backend code migrations; admins read them but do not mutate them
- **Rule-as-authoritative SQL compilation (Tier 2)** — this PRD describes the target state (`cpt-metric-cat-fr-rule-compiles-to-sql`) but does not ship it. In v1, rules are descriptive artifacts validated by invariant tests; `query_ref` remains hand-written by product engineers. Compilation lands in catalog v2.
- Formal schema language for calculation rules beyond a JSON structure with enumerated fields — a richer DSL (joins, windows, CTEs) is deferred to the v2 work where compile-from-rule is in scope
- Tenant-level edits of semantic metadata (labels, units, formats) in v1 — keeping the product team as the owner of metadata avoids drift across tenants and keeps i18n manageable
- Dashboard-scoped threshold overrides — referenced here as an optional scope but owned by the Dashboard Configurator PRD
- Alerting rule engine — a future consumer of the catalog, not part of this PRD
- Cross-tenant catalog sharing or federation
- Soft delete / audit log of metadata changes beyond timestamps
- Metric `query_ref` storage — stays in the existing `analytics.metrics` table; calculation rules in this PRD describe what `query_ref` is supposed to do without replacing it in v1

## 5. Functional Requirements

### 5.1 Catalog Storage

#### Catalog Persists Semantic Metadata per Tenant per Metric

- [ ] `p1` - **ID**: `cpt-metric-cat-fr-catalog-storage`

The system **MUST** persist one row per `(tenant_id, metric_key)` in `metric_catalog` with at least: `label_i18n_key`, `sublabel_i18n_key`, `description_i18n_key`, `unit`, `format`, `higher_is_better`, `is_member_scale`, `source_tag`, `is_enabled`, `created_at`, `updated_at`. The `(tenant_id, metric_key)` pair **MUST** be unique.

**Rationale**: One canonical place for every fact about a metric. Per-tenant isolation allows future per-tenant metadata customization (e.g., localization) without a schema change.

**Actors**: `cpt-metric-cat-actor-analytics-api`, `cpt-metric-cat-actor-mariadb`

#### Catalog Enable Flag Controls Visibility

- [ ] `p1` - **ID**: `cpt-metric-cat-fr-enable-flag`

The system **MUST** honor `is_enabled = false` by excluding the row from `GET /catalog/metrics`. Existing consumers (e.g., dashboards) referencing a disabled metric **MUST** continue to work — the reference resolves as absent rather than erroring — so downstream systems can tolerate deprecations without coordinated rollbacks.

**Rationale**: Deprecation lifecycle needs a mechanism that does not break production surfaces the moment a row is disabled.

**Actors**: `cpt-metric-cat-actor-consumer`

### 5.2 Threshold Storage and Resolution

#### Tenant-Scoped Thresholds

- [ ] `p1` - **ID**: `cpt-metric-cat-fr-tenant-thresholds`

The system **MUST** persist thresholds in `metric_threshold` keyed on `(tenant_id, metric_key)` with fields for `good`, `warn`, `alert_trigger` (optional), and `alert_bad` (optional). When a tenant has no row for a given `metric_key`, the system **MUST** fall back to product-seeded defaults (shipped as another row scoped to the zero-tenant or an equivalent "default" marker).

**Rationale**: Compliance, engineering, and support teams in the same tenant can converge on their own numerical targets without a product change. Fallback to a seeded default keeps every metric colorable out of the box.

**Actors**: `cpt-metric-cat-actor-tenant-admin`, `cpt-metric-cat-actor-product-team`

#### Scoped Threshold Overrides

- [ ] `p2` - **ID**: `cpt-metric-cat-fr-scoped-thresholds`

The system **SHOULD** support scopes narrower than `tenant` for thresholds. The full scope set is:

- `product-default` — seeded floor, shipped with the migration, applies when no narrower row exists
- `tenant` — per-tenant default (ships mandatory in v1 per `cpt-metric-cat-fr-tenant-thresholds`)
- `dashboard` — override tied to a specific `dashboard_id`; applies to any metric reference from that dashboard regardless of team. Because dashboards are keyed by `(view_type, role)` in the Dashboard Configurator, this scope implicitly covers role-specific overrides without needing a separate `role` scope.
- `team` — override tied to a specific `team_id`; applies to the team across all dashboards. Requires Dashboard Configurator's team-lead customization feature to be usable by admins, so it lands alongside that feature.
- Composite `team + dashboard` — override tied to the pair; most specific, used when a team lead wants a threshold that applies only to their team's view of a specific dashboard.

Resolution precedence **MUST** be, most specific wins: `team + dashboard → team → dashboard → tenant → product-default`. The resolution rule is canonical; consumers do not reimplement it. Admin writes **MUST** populate `scope` explicitly and **MUST** carry the matching `dashboard_id` / `team_id` FKs for narrower scopes.

**Rationale**: Different dashboards, teams, and roles within the same tenant may legitimately disagree on what "good" means. A compliance team and an engineering team can share a tenant but use different focus-time targets. The catalog owns the resolution order so every consumer agrees. Role scope folds into `dashboard` because dashboards already carry role — adding a distinct `role` scope would double-count. Team scope is orthogonal to dashboards because team leads need to nudge their team's bar without forking the composition.

**Actors**: `cpt-metric-cat-actor-consumer`, `cpt-metric-cat-actor-tenant-admin`

### 5.3 Read API

#### GET /catalog/metrics Returns Fully Resolved Catalog

- [ ] `p1` - **ID**: `cpt-metric-cat-fr-read-endpoint`

The system **MUST** expose `GET /catalog/metrics` returning, for the caller's tenant, every `is_enabled = true` catalog row joined with its resolved thresholds per `cpt-metric-cat-fr-scoped-thresholds` and its calculation rule per `cpt-metric-cat-fr-calc-rule-storage`. The response **MUST** include a `tenant_id` echo and a `generated_at` timestamp to support client-side caching.

**Rationale**: Consumers need one call to hydrate everything they need about every metric they will render or evaluate — metadata, thresholds, and calculation rule together. Round-trips per metric would be unacceptable.

**Actors**: `cpt-metric-cat-actor-consumer`, `cpt-metric-cat-actor-analytics-api`

#### Read Endpoint Is Cacheable

- [ ] `p1` - **ID**: `cpt-metric-cat-fr-cache`

The system **MUST** front the read endpoint with a cache layer whose default TTL is 5 minutes and whose cache key includes the tenant identifier. Admin writes **MUST** invalidate the cache for the affected tenant so threshold changes appear on the next page load.

**Rationale**: The catalog is high-read low-write; stale reads beyond a few minutes are acceptable but stale reads after an admin write are not — they produce the "I changed the threshold, nothing happened" support call.

**Actors**: `cpt-metric-cat-actor-analytics-api`

### 5.4 Admin Write API

#### Threshold CRUD Endpoints

- [ ] `p1` - **ID**: `cpt-metric-cat-fr-threshold-crud`

The system **MUST** expose `POST /v1/admin/metric-thresholds`, `PUT /v1/admin/metric-thresholds/:id`, and `DELETE /v1/admin/metric-thresholds/:id` for tenant admins. Writes **MUST** enforce (a) authorization checking that the caller is a tenant admin for the target tenant, (b) referential integrity with `metric_catalog`, (c) sanity bounds (e.g., `warn ≤ good` for metrics where `higher_is_better = true`).

**Rationale**: Admins need a supported way to change thresholds. Validation prevents the "I accidentally set good below warn" class of mistakes from reaching the UI.

**Actors**: `cpt-metric-cat-actor-tenant-admin`, `cpt-metric-cat-actor-analytics-api`

#### Metadata Writes Are Migration-Only in v1

- [ ] `p1` - **ID**: `cpt-metric-cat-fr-metadata-writes`

The system **MUST NOT** expose a runtime admin endpoint to edit `metric_catalog` metadata (labels, units, formats, `higher_is_better`). Metadata changes **MUST** ship as backend code migrations reviewed through the normal release process. Disabling a metric via `is_enabled = false` **MAY** be exposed to admins in a future follow-up.

**Rationale**: Metadata drift across tenants would fragment comparability of the product. Letting a single tenant unilaterally rename `tasks_closed` to "Story Points Completed" would break cross-tenant comparisons and i18n. Thresholds are local policy; metadata is product-level contract.

**Actors**: `cpt-metric-cat-actor-product-team`

### 5.5 Calculation Rules

#### Catalog Persists a Calculation Rule per Metric

- [ ] `p1` - **ID**: `cpt-metric-cat-fr-calc-rule-storage`

The system **MUST** persist a structured calculation rule per `metric_key`, either as a dedicated `metric_calculation` table or as a JSON column on `metric_catalog` (the exact shape is a DESIGN decision). Every rule **MUST** cover at minimum:

- `aggregation` — the function applied when the metric is rolled up across rows (`sum`, `avg`, `max`, `min`, `median`, `percentile`, `rate`, `count`, `count_distinct`, or `identity` for already-computed values)
- `source` — a reference to the view/table and column(s) the metric is derived from (e.g., `insight.team_member.focus_time_pct`)
- `grain` — the temporal and entity grain at which the metric is emitted (`per-person-per-day`, `per-team-per-period`, `per-org-per-period`, etc.)
- `null_policy` — how nulls are handled (`preserve`, `skip` for `avg`/`median`, `treat_as_zero` where justified)
- `bounds` (optional) — numeric clamp `{ min, max }` when the metric is semantically bounded (e.g., percentages clamped to 0-100)
- `formula` (optional, for derived metrics) — references to other metric keys or raw fields used to compute this metric, plus a short description (e.g., `numerator / denominator * 100`)

**Rationale**: Calculation logic is today opaque inside ClickHouse SQL. A structured rule makes it readable by non-engineers, comparable across metrics, and machine-checkable against the SQL in CI. The rule is declarative and does not execute in v1.

**Actors**: `cpt-metric-cat-actor-product-team`

#### Each Metric Links to Its Primary Query

- [ ] `p1` - **ID**: `cpt-metric-cat-fr-query-linkage`

Every `metric_catalog` row **MUST** carry a non-null `primary_query_id` foreign key into `analytics.metrics.id`, identifying the ClickHouse query that produces this `metric_key`'s values. The link **MUST** survive any future `metric_query` reorganization via either FK constraints or migration-time checks. When a rare metric is genuinely emitted by multiple queries, this PRD handles only the primary; secondary references are an Open Question.

**Rationale**: Any caller — admin UI, PR reviewer, alerting, on-call debugging — needs to answer "show me the SQL for `focus_time_pct`" in one hop. Storing the link as an indexed column gives O(1) navigation and survives schema changes on either side. Deriving the link at runtime by SQL-scanning is fragile.

**Actors**: `cpt-metric-cat-actor-product-team`, `cpt-metric-cat-actor-consumer`

#### Reverse Lookup — Query → Metric Keys

- [ ] `p1` - **ID**: `cpt-metric-cat-fr-query-reverse-lookup`

The system **MUST** expose `GET /v1/admin/metric-queries/:query_id/metric-keys` returning every `metric_key` in `metric_catalog` that references the given `analytics.metrics.id`. Authorization is restricted to tenant admins.

**Rationale**: When a product engineer changes a `query_ref` in a PR, they need to know which catalog entries are affected without manually grepping. Reverse lookup gives an auditable list in one call and powers the CI coupling check in `cpt-metric-cat-fr-calc-rule-coupling`.

**Actors**: `cpt-metric-cat-actor-product-team`, `cpt-metric-cat-actor-tenant-admin`

#### One-Shot Admin Diagnostics

- [ ] `p1` - **ID**: `cpt-metric-cat-fr-admin-diagnostics`

The system **MUST** expose `GET /v1/admin/metric-diagnostics/:metric_key` returning in a single response: the catalog row, resolved thresholds, the calculation rule, the primary query's UUID plus its `query_ref` SQL, and metadata about the last successful execution (rowcount, latency, timestamp). Authorization is restricted to tenant admins.

**Rationale**: Debugging "why does this metric look wrong" today means jumping between MariaDB, ClickHouse, a Rust file, and a React file. A single admin-authorized endpoint that returns the full picture cuts this from a 10-minute hunt to a 1-second lookup.

**Actors**: `cpt-metric-cat-actor-tenant-admin`, `cpt-metric-cat-actor-product-team`

#### Calculation Rules Ship Alongside `query_ref` Changes

- [ ] `p1` - **ID**: `cpt-metric-cat-fr-calc-rule-coupling`

When a product engineer adds, modifies, or deprecates a metric, the pull request **MUST** update the calculation rule in the same review as the `query_ref` SQL. Backend CI **MUST** run a consistency check that fails the PR when a `query_ref` is changed without a corresponding calculation-rule change or vice versa. The check is a heuristic first line — it catches "forgot to update one side" cases but is not a proof of equivalence. The stronger proof is the invariant-test FR below.

**Rationale**: Coupling at review time catches the cheap drift cases cheaply. The expensive cases — where both sides change but in subtly different directions — fall to invariant tests.

**Actors**: `cpt-metric-cat-actor-product-team`

#### Invariant Tests Enforce Rule/SQL Consistency

- [ ] `p1` - **ID**: `cpt-metric-cat-fr-invariant-tests`

The system **MUST** ship executable invariant tests that run per metric in backend CI. For each enabled `metric_key`, the test runner **MUST** execute the metric's primary `query_ref` against a shared fixture dataset and assert that observed behavior matches the declared calculation rule. At minimum, the following invariants **MUST** be checked when the corresponding rule field is set:

- `aggregation`: the query's output on a fixture with a known expected aggregate matches within floating-point tolerance
- `null_policy`: the query's output on an all-null input matches the declared behavior (`NULL` for `preserve`, the aggregation of non-nulls for `skip`, zero where `treat_as_zero` is declared)
- `bounds`: every output row on an edge-case fixture (negative, above max, non-finite) falls within the declared clamp
- `grain`: the output row count and grouping keys match the declared grain — per-person-per-day fixtures produce per-person-per-day output rows

Failed invariants **MUST** fail CI with a report naming the specific metric, the failing invariant, the declared rule value, and the observed value.

**Rationale**: Coupling gates catch absent updates; invariant tests catch wrong updates. Together they reduce rule↔SQL drift from "discovered in production" to "caught on PR" — the main fear behind introducing a descriptive rule in the first place.

**Actors**: `cpt-metric-cat-actor-product-team`

#### Calculation Rules Are Returned with the Catalog

- [ ] `p1` - **ID**: `cpt-metric-cat-fr-calc-rule-response`

`GET /catalog/metrics` **MUST** include each metric's calculation rule and its `primary_query_id` in the response payload. Consumers **MAY** use the rule to render human-readable "how is this calculated?" tooltips, build admin diagnostics, or evaluate alerting suitability.

**Rationale**: Admins and downstream tools need the rule at the same time as the rest of the metadata; a separate endpoint is unnecessary friction.

**Actors**: `cpt-metric-cat-actor-consumer`

#### Target v2 — Simple Rules Compile to SQL

- [ ] `p2` - **ID**: `cpt-metric-cat-fr-rule-compiles-to-sql`

In a future revision of the catalog (target v2), the system **SHOULD** compile simple calculation rules — those expressible as a single aggregation over a single view/column with optional filters and clamps — directly into ClickHouse SQL at deploy time. For those metrics the rule becomes authoritative and `analytics.metrics.query_ref` is generated, not hand-written. Complex metrics (derived, multi-source, windowed) carry an explicit `sql_override` flag in the rule and retain a hand-authored `query_ref`. Invariant tests continue to run for both kinds.

This FR is tracked at `p2` and is **not** shipped in v1 of the catalog. The surrounding contract (rule storage, linkage, invariant tests) is designed so adopting rule-compilation later is additive, not a schema rewrite.

**Rationale**: In the long run, the only way to guarantee rule↔SQL consistency is to make them the same artifact. Industry-standard approach (dbt Semantic Layer, Cube.js, Looker/LookML). Calling this out as a `p2` target in the v1 PRD communicates the direction without committing to the engineering cost now, and keeps DESIGN decisions (JSON column vs dedicated table, enum-only vs open fields in rule) oriented toward the eventual compilation.

**Actors**: `cpt-metric-cat-actor-product-team`

### 5.6 Seed and Migration

#### Seed from Frontend Metadata

- [ ] `p1` - **ID**: `cpt-metric-cat-fr-seed-from-frontend`

The system **MUST** seed the initial catalog by importing the metadata currently hardcoded in `src/screensets/insight/api/thresholdConfig.ts` (`BULLET_DEFS`, `IC_KPI_DEFS`) and `src/screensets/insight/types/index.ts` (`METRIC_KEYS`). The system **MUST** also seed an initial calculation rule for every seeded metric, authored by the product team to mirror the actual behavior of each metric's `query_ref` and the upstream gold views it depends on. The seed is a one-time export that the product team reviews before merging. After the seed lands and the frontend consumes `GET /catalog/metrics`, the duplicated metadata on the frontend **MUST** be removed as part of the same release.

**Rationale**: Zero-downtime migration: on day one, the catalog returns the same values the frontend was hardcoding, so no visible change for end users. The delete-from-frontend step follows immediately so there is no period of dual maintenance.

**Actors**: `cpt-metric-cat-actor-product-team`

#### Existing Empty `analytics.thresholds` Table Resolved

- [ ] `p1` - **ID**: `cpt-metric-cat-fr-thresholds-table-resolution`

The system **MUST** explicitly resolve the fate of the existing empty `analytics.thresholds` table in the same migration series that introduces `metric_threshold`. Options: (a) rename `thresholds` → `metric_threshold` and extend the schema, (b) drop `thresholds` and create a fresh `metric_threshold`, (c) keep `thresholds` as a generic threshold store and reference it from the catalog. The chosen option is tracked in Open Questions and selected in DESIGN; leaving the ambiguity unresolved is not allowed.

**Rationale**: Orphaned empty tables with unclear purpose cause future confusion. Picking a path now keeps the migration file honest.

**Actors**: `cpt-metric-cat-actor-product-team`

## 6. Non-Functional Requirements

### 6.1 NFR Inclusions

#### Performance — Catalog Read Latency

- [ ] `p1` - **ID**: `cpt-metric-cat-nfr-read-latency`

`GET /catalog/metrics` p95 response time **MUST** be ≤ 100ms on a cache hit and ≤ 500ms on a cache miss for a tenant with up to 200 catalog rows.

**Threshold**: p95 ≤ 100ms (hit), ≤ 500ms (miss), measured at the analytics-api service level.

#### Consistency — Write-After-Read Visibility

- [ ] `p1` - **ID**: `cpt-metric-cat-nfr-write-visibility`

A successful threshold write **MUST** be visible to subsequent `GET /catalog/metrics` calls from the same tenant within one cache TTL, with no manual invalidation required.

**Threshold**: 99th-percentile propagation ≤ default cache TTL + 5s buffer.

#### Reliability — Safe Concurrent Admin Writes

- [ ] `p2` - **ID**: `cpt-metric-cat-nfr-concurrent-writes`

Concurrent admin writes to the same threshold row **MUST** result in a consistent final state (last-write-wins is acceptable; interleaved corruption is not).

**Threshold**: zero observed interleave in a concurrent-write soak test at 50 QPS for 60s.

### 6.2 NFR Exclusions

- **Accessibility** (UX-PRD-002): Not applicable — catalog is a backend service with no direct UI surface.
- **Internationalization** (UX-PRD-003): The catalog stores `*_i18n_key` references; actually delivering localized copy is outside scope and belongs to the i18n program.
- **Multi-region** (OPS-PRD-005): Not applicable — catalog is per-tenant and tenants are single-region today.
- **Offline support** (UX-PRD-006): Not applicable — consumers are online services.

## 7. Public Library Interfaces

### 7.1 Public API Surface

#### GET /catalog/metrics

- [ ] `p1` - **ID**: `cpt-metric-cat-interface-read`

**Type**: REST API

**Stability**: stable

**Description**: Returns the catalog for the caller's tenant, filtered to `is_enabled = true`, with resolved thresholds per the precedence rule in `cpt-metric-cat-fr-scoped-thresholds` and calculation rules per `cpt-metric-cat-fr-calc-rule-storage`. Response shape: `{ tenant_id, generated_at, metrics: [{ metric_key, label_i18n_key, sublabel_i18n_key, description_i18n_key, unit, format, higher_is_better, is_member_scale, source_tag, primary_query_id, thresholds: { good, warn, alert_trigger?, alert_bad? }, calc_rule: { aggregation, source, grain, null_policy, bounds?, formula? } }] }`.

**Breaking Change Policy**: Adding optional fields is non-breaking. Renaming or removing fields requires a major version bump and a two-minor-version deprecation window.

#### GET /v1/admin/metric-diagnostics/:metric_key

- [ ] `p1` - **ID**: `cpt-metric-cat-interface-admin-diagnostics`

**Type**: REST API (tenant-admin-only)

**Stability**: stable

**Description**: Returns the full picture for a single metric in one call — catalog row, resolved thresholds, calculation rule, primary query (UUID + `query_ref` SQL), and last-run metadata. Response shape: `{ metric_key, catalog: {...}, thresholds: {...}, calc_rule: {...}, primary_query: { id, name, query_ref, last_run: { status, rowcount, latency_ms, executed_at } } }`.

**Breaking Change Policy**: Additive changes non-breaking; field removal is a major bump.

#### GET /v1/admin/metric-queries/:query_id/metric-keys

- [ ] `p1` - **ID**: `cpt-metric-cat-interface-reverse-lookup`

**Type**: REST API (tenant-admin-only)

**Stability**: stable

**Description**: Given an `analytics.metrics.id` UUID, returns every `metric_key` in the tenant's catalog whose `primary_query_id` matches. Response shape: `{ query_id, metric_keys: [{ metric_key, label_i18n_key, is_enabled }] }`.

**Breaking Change Policy**: Additive changes non-breaking.

#### POST/PUT/DELETE /v1/admin/metric-thresholds

- [ ] `p1` - **ID**: `cpt-metric-cat-interface-admin`

**Type**: REST API

**Stability**: stable

**Description**: Admin CRUD for `metric_threshold` rows. Authorization enforced per `cpt-metric-cat-fr-threshold-crud`. Payload validates against `metric_catalog` (`metric_key` must exist and be `is_enabled = true`) and against sanity bounds tied to `higher_is_better`.

**Breaking Change Policy**: Field additions non-breaking; removal is a major bump.

### 7.2 External Integration Contracts

#### Catalog Consumer Contract

- [ ] `p1` - **ID**: `cpt-metric-cat-contract-consumer`

**Direction**: provided by library

**Protocol/Format**: Consumers **MUST** fetch `GET /catalog/metrics` once per session (or per cache-TTL window), key metadata lookups by `metric_key`, and degrade gracefully when a `metric_key` is absent from the response. Consumers **MUST NOT** hardcode metric metadata that the catalog provides.

**Compatibility**: Additive response fields are non-breaking. Catalog entries that disappear (disabled) should be treated by consumers as absent-metadata, not as errors.

## 8. Use Cases

### UC-001 Admin Tunes a Threshold

**ID**: `cpt-metric-cat-usecase-tune-threshold`

**Actor**: `cpt-metric-cat-actor-tenant-admin`

**Preconditions**: Admin has tenant-admin authorization. Target `metric_key` exists in the catalog and is `is_enabled = true`.

**Main Flow**:

1. Admin opens the (future) admin UI or hits the admin API directly
2. Admin submits a new threshold for a `(tenant_id, metric_key)` pair
3. API validates payload — `metric_key` exists, sanity bounds hold, admin is authorized for the tenant
4. API persists the row and invalidates the cache entry for the tenant
5. Next `GET /catalog/metrics` for the tenant returns the new threshold
6. Dashboards in the tenant re-render bullets with the new color policy on their next load

**Postconditions**: Tenant's threshold is updated; no code deploy was required.

**Alternative Flows**:

- **Validation fails**: Payload rejected with a specific error; no state mutated.
- **Admin lacks authorization**: Request rejected with `403`; audit event logged.

### UC-002 Product Team Adds a New Metric

**ID**: `cpt-metric-cat-usecase-new-metric`

**Actor**: `cpt-metric-cat-actor-product-team`

**Preconditions**: The new metric's `metric_query` is either being added in the same PR or already exists in `analytics.metrics`. i18n keys for the new metric are planned in the i18n loader.

**Main Flow**:

1. Product engineer writes a sea-orm migration that inserts one `metric_catalog` row per tenant with appropriate metadata **and** a calculation rule describing how the metric is computed (aggregation, source, grain, null policy, bounds if any)
2. The same PR updates the consuming frontend / service to reference the new `metric_key` and adds or modifies the ClickHouse `query_ref` row if needed
3. CI runs the `cpt-metric-cat-fr-calc-rule-coupling` consistency check and fails the PR if the calculation rule was not updated alongside `query_ref` changes
4. Migration runs at service startup in every environment
5. `GET /catalog/metrics` returns the new entry (metadata + rule) after cache expiry or invalidation
6. Consumers that know the `metric_key` start rendering / evaluating it; admin UIs render the calculation rule as a "how is this computed?" tooltip

**Postconditions**: The new metric is catalog-backed with a calculation rule; no hardcoded metadata exists anywhere.

**Alternative Flows**:

- **Metric is sensitive to only some tenants**: The migration inserts only for those tenants; others see no entry.
- **Metric is a replacement for an older one**: The older `metric_key` is set to `is_enabled = false` in the same migration; consumers using it fall back to absent-metadata and degrade gracefully.

### UC-003 Consumer Hydrates the Catalog

**ID**: `cpt-metric-cat-usecase-consumer-hydrate`

**Actor**: `cpt-metric-cat-actor-consumer`

**Preconditions**: Consumer has a valid tenant-scoped auth token.

**Main Flow**:

1. Consumer calls `GET /catalog/metrics`
2. API resolves threshold precedence and returns the catalog
3. Consumer caches the response for at most the TTL
4. Consumer uses `metric_key` as the lookup key for any metric-related rendering or evaluation

**Postconditions**: Consumer has a coherent snapshot of the tenant's catalog for the cache window.

**Alternative Flows**:

- **Catalog empty or all-disabled**: Consumer degrades gracefully (render ComingSoon, skip alert evaluation).
- **API 5xx**: Consumer uses last-good cached copy if any; otherwise surfaces a diagnostic error.

## 9. Acceptance Criteria

- [ ] `metric_catalog`, `metric_threshold`, and calculation-rule storage (table or column) exist in analytics-api's MariaDB, with sea-orm migrations that seed the frontend metadata and authored calculation rules one-to-one
- [ ] `GET /catalog/metrics` returns resolved thresholds and calculation rules, filters by `is_enabled`, and is cached with a 5-minute TTL
- [ ] Every seeded metric has a calculation rule covering at minimum `aggregation`, `source`, `grain`, and `null_policy`; rules missing any required field fail the seed migration
- [ ] `POST /v1/admin/metric-thresholds` persists a new threshold and invalidates the tenant's cache; the value is visible to the next `GET /catalog/metrics` without waiting for TTL
- [ ] An attempt to create a threshold with `warn > good` on a `higher_is_better = true` metric is rejected with a validation error
- [ ] The frontend ships a release that removes `BULLET_DEFS`, `IC_KPI_DEFS`, and the metric-metadata portion of `METRIC_KEYS`, hydrating from `GET /catalog/metrics` instead, with no visible change to end users on day one
- [ ] The empty `analytics.thresholds` table is explicitly resolved (renamed, extended, or dropped) in the same migration series
- [ ] Disabling a metric via `is_enabled = false` does not error any consumer that was previously rendering it; the consumer degrades gracefully
- [ ] Adding a new `metric_query` row in a PR without a corresponding calculation rule (or vice versa) fails the CI consistency check from `cpt-metric-cat-fr-calc-rule-coupling`
- [ ] Every enabled `metric_catalog` row has a non-null `primary_query_id` referencing an existing `analytics.metrics.id`; referential integrity is enforced at the DB or migration level
- [ ] `GET /v1/admin/metric-diagnostics/:metric_key` returns the full picture (catalog + thresholds + rule + `query_ref` + last-run metadata) in a single call with median response under 250ms on a cache hit
- [ ] `GET /v1/admin/metric-queries/:query_id/metric-keys` returns the exact list of `metric_key` values that reference a given query UUID
- [ ] Backend CI runs invariant tests per metric per `cpt-metric-cat-fr-invariant-tests`; a calculation rule that declares `aggregation = avg` and `null_policy = skip` fails CI if the corresponding `query_ref` returns `0` instead of `NULL` on an all-null fixture
- [ ] Modifying `query_ref` SQL for a metric without adjusting invariant-test fixtures fails CI when the change violates a declared invariant
- [ ] Threshold resolution for a request with (tenant, dashboard, team) context returns the most specific row per the precedence `team + dashboard → team → dashboard → tenant → product-default`, and the response surfaces which scope supplied the value
- [ ] Attempting to create a threshold with `scope = 'dashboard'` and a null `dashboard_id` (or `scope = 'team'` and a null `team_id`) is rejected with a validation error
- [ ] When Dashboard Configurator's team-lead customization ships and a team lead writes a team-scoped threshold, subsequent `GET /catalog/metrics` calls from viewers scoped to that team see the team's value while other teams in the same tenant see the unchanged dashboard-scope or tenant-scope value

## 10. Dependencies

| Dependency | Description | Criticality |
|------------|-------------|-------------|
| MariaDB | Hosts `metric_catalog`, `metric_threshold`, and calculation-rule storage | p1 |
| Analytics API service | Hosts the read and admin write endpoints | p1 |
| Existing `analytics.metrics` table | Holds `query_ref` rows; catalog calculation rules describe what each `query_ref` is supposed to compute. Keyed by UUID; one `query_ref` can emit multiple `metric_key` values | p1 |
| Frontend i18n loader | Resolves `label_i18n_key`, `sublabel_i18n_key`, `description_i18n_key` values to display strings | p2 (for FE consumers) |
| Auth / RBAC | Authorizes tenant-admin writes against threshold CRUD | p1 |

## 11. Assumptions

- Tenants are single-region; the catalog does not need multi-region replication.
- i18n keys are resolved by consumers (the frontend i18n loader today; future backend consumers may embed a resolver or display the raw keys in admin contexts).
- The product team is the owner of metric semantics in v1; tenants cannot rename labels or change units without a code change. This is intentional per `cpt-metric-cat-fr-metadata-writes`.
- Auth plumbing (tenant admin detection) exists or will be provided alongside this work; modelling new auth primitives is outside scope.
- Cache layer (Redis, in-process LRU, or equivalent) is available in the analytics-api service stack.

## 12. Risks

| Risk | Impact | Mitigation |
|------|--------|------------|
| Seed-from-frontend import introduces subtle metadata divergence | UI regressions on day one of rollout | Byte-for-byte comparison between rendered bullet output before and after migration; hold the frontend-delete step until comparison passes |
| Cache invalidation on admin write is missed for a request path | "I changed the threshold, nothing happened" support calls | Centralized invalidation helper in analytics-api; invalidation covered by integration tests at every admin write endpoint |
| Existing empty `analytics.thresholds` table left ambiguous causes confusion | Future engineers treat it as the live threshold store and diverge | `cpt-metric-cat-fr-thresholds-table-resolution` forces a migration-time decision |
| Metadata writes open up via admin UI in a later version without discipline | Cross-tenant drift of metric meaning; i18n explosion | `cpt-metric-cat-fr-metadata-writes` prohibits runtime metadata edits in v1; future PRDs that propose relaxing this must address the cross-tenant comparability trade-off explicitly |
| Threshold override precedence misunderstood by consumers | Inconsistent bullet colors across surfaces for the same metric | `cpt-metric-cat-fr-scoped-thresholds` fixes precedence; the `GET /catalog/metrics` response always returns the resolved value plus the source scope for debuggability |
| Calculation rule drifts from `query_ref` SQL over time | Admin-visible "how is this calculated?" text is wrong; downstream tools reason incorrectly about metrics | Three-layer defense: coupling gate at review time (`cpt-metric-cat-fr-calc-rule-coupling`) catches "forgot to update one side"; invariant tests (`cpt-metric-cat-fr-invariant-tests`, `p1` in v1) catch "updated both but wrong"; rule-compiles-to-SQL for simple metrics (`cpt-metric-cat-fr-rule-compiles-to-sql`, `p2` target v2) eliminates drift by construction for the bulk of metrics. Rule is documented as descriptive in v1; consumers that need ground truth still read `query_ref` |
| Calculation rule schema too rigid, cannot express derived or windowed metrics | Some metrics end up with a placeholder rule that says less than the SQL; rule loses value | Rule schema includes an optional `formula` free-text field for edge cases; DESIGN chooses the minimal rigid fields and allows prose where structure falls short |
| Calculation rule schema too loose, consumers cannot rely on specific fields | Admin UI cannot consistently render "aggregation / source / grain"; alerting cannot evaluate suitability | `cpt-metric-cat-fr-calc-rule-storage` fixes the minimum required fields; seed migration fails if any are missing |
| `primary_query_id` becomes stale after a `metric_query` reorg | Admin diagnostics and reverse lookup point at wrong UUIDs; debugging misleads | Migration runs an integrity check on every deploy (`SELECT … WHERE primary_query_id NOT IN (SELECT id FROM metrics)` returns zero); CI rejects schema migrations to `analytics.metrics` that don't update `metric_catalog.primary_query_id` for renames |
| Invariant-test fixture dataset diverges from real production shapes | CI passes but production behavior surprises users | Fixture dataset is shared across invariant tests, version-controlled, and reviewed alongside rule additions; a separate periodic canary job runs invariants against a rotated snapshot of real tenant data (Open Question) |
| Scope explosion if future PRDs keep adding scopes (e.g., `role`, `org_unit`, `period`, `seniority`) | Precedence chain becomes unmaintainable, admins cannot predict which row wins | Resolution precedence is canonical and lives in the catalog. This PRD commits to the set `{product-default, tenant, dashboard, team, team + dashboard}` for v1/v2 and treats new scopes as a major-version bump. Role is explicitly folded into `dashboard` rather than added as a distinct scope (see glossary). Future scope additions require a DESIGN / ADR that updates the precedence diagram. |
| Team-scoped threshold written by a team lead contradicts a tenant admin's rollout intent | Org-wide comparability fragments silently across teams | Admin-scope diagnostics endpoint (`cpt-metric-cat-fr-admin-diagnostics`) exposes the full scope chain for each metric so tenant admins can audit which teams have overrides and why; governance can require justification or expiry on team-scoped thresholds (Open Question) |
| `team_id` referenced from the catalog is a free-form string (currently derived from BambooHR department) with no referential integrity | Stale or misspelled team_ids persist in `metric_threshold` after org reshuffles | DESIGN picks between string-based `team_id` (pragmatic, no new table) and a dedicated `team_catalog` (referential integrity but bigger scope); integrity check in migrations as an interim measure (see Open Questions) |

## 13. Open Questions

| Question | Owner | Target Resolution |
|----------|-------|-------------------|
| Existing empty `analytics.thresholds` table — rename/extend, drop, or keep as a generic store? Must be decided in the same migration series that creates `metric_threshold`. | Backend tech lead | DESIGN phase |
| Should the catalog support per-tenant metadata localization (tenant admin rewriting `label_i18n_key`), or is the product-team-owned model sufficient long-term? Trade-off: cross-tenant comparability vs tenant-specific terminology. | Insight Product Team | Before the second tenant onboards |
| Source of truth for `label_i18n_key` strings — are they defined in the backend seed migration and consumed by the frontend i18n loader, or defined in the frontend i18n loader and referenced by the migration? | Insight Product Team + Frontend tech lead | Before the seed migration PR |
| Alerting consumer contract — will alerting use the same `GET /catalog/metrics` endpoint or a narrower `GET /catalog/metrics?for=alerting` variant? | Insight Product Team | Before alerting PRD kicks off |
| Soft-delete / audit log of threshold changes — ship in v1 or defer? Regulated tenants may require it from day one. | Insight Product Team | Before v1 is cut |
| Calculation rule storage shape — dedicated `metric_calculation` table with typed columns, or a JSON column on `metric_catalog`? Trade-off: normalized schema enables SQL-level validation but rigidifies schema changes; JSON column is flexible but shifts validation to app layer. | Backend tech lead | DESIGN phase |
| Minimum rule schema for v1 — exactly which aggregation values, which grains, which null policies do we enumerate? Enumerated lists prevent typos but close the door on future kinds. | Insight Product Team + Backend tech lead | Before seed migration PR |
| Invariant-test scaffolding scope for v1 — ship the full matrix required by `cpt-metric-cat-fr-invariant-tests` (aggregation / null policy / bounds / grain) on day one, or start with a subset and extend? Depends on availability of representative fixture data and test-runner infrastructure. | Backend tech lead | Before v1 is cut |
| Derived-metric formula expression — free-text human-readable prose, structured references to other metric keys, or both? Affects whether rules can be auto-rendered or auto-validated for derivations. | Insight Product Team | DESIGN phase |
| Multi-query metrics — are there any `metric_key` values that genuinely come from more than one `analytics.metrics` UUID? If yes, the `primary_query_id` column alone is insufficient and we need a join table from day one. Inventory current ~40 metrics against existing seed UUIDs before picking a shape. | Backend tech lead | Before the seed migration PR |
| Invariant-test fixture dataset — hand-crafted synthetic fixtures, or a sanitized snapshot of a real tenant? Fixtures are deterministic but miss real-world shapes; snapshots are realistic but require sanitization pipelines. | Backend tech lead | Before the first batch of invariant tests lands |
| Periodic canary of invariants against real data — is this part of v1, or a follow-up? If v1, we need to schedule job infrastructure alongside the basic CI tests. | Backend tech lead | Before v1 is cut |
| Rule-compiles-to-SQL DSL (Tier 2) — is a separate DESIGN doc needed before v2 work kicks off, or can it be scoped directly in the v2 PRD? DSL design is non-trivial and affects how we author rules in v1 (which should be forward-compatible). | Insight Product Team + Backend tech lead | Before v2 PRD starts |
| `team_id` referencing — store as free-form string matching the existing `org_unit_id` used in dashboards, or introduce a `team_catalog` table with FK integrity? String is pragmatic for v1; team_catalog is cleaner long-term but is effectively a new sub-PRD. | Backend tech lead | Before team-scoped thresholds ship (post Dashboard Configurator team-lead customization) |
| Team-scoped threshold governance — should a tenant admin be able to (a) see all team overrides in a diagnostics view, (b) require justification or expiry on team overrides, (c) cap how far a team threshold may diverge from tenant default? Without governance, well-meaning team leads drift the bar. | Insight Product Team | Before team-lead threshold UI ships |
| Should the resolution rule surface the winning scope to the consumer (e.g., `thresholds.resolved_from: 'team'`) by default, or only in diagnostics? Adding it by default is useful for debugging but bloats every catalog read. | Backend tech lead | Before `cpt-metric-cat-fr-scoped-thresholds` ships |
