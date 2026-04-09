# Insight — GitHub Project Task List

> **Priority legend** (optimized for fastest end-to-end test release):
> - **P0** — Critical path: blocks first e2e test installation
> - **P1** — Needed for meaningful e2e demo with real data & charts
> - **P2** — Second wave: important features after initial release
> - **P3** — Hardening & advanced features
>
> **Estimation**: each task ≤ 2–3 man·days
>
> **Key constraint** (per Roman): this is **on-prem** — no "deploys", only **releases**. The Helm chart is the installer; it must provision all dependencies (ClickHouse, MariaDB, Redis, etc.) so the user doesn't install them manually.
>
> **Planning assumptions** (validated against architect inputs + decomposition):
> - Explicit prerequisites are part of the plan and block downstream work.
> - **Phase 1** (data foundation) and **Phase 2** (UI/backend foundation) can run in parallel where dependencies allow.
> - Connector expansion beyond the approved Priority-1 scope stays in a separate backlog.
> - The first milestone is an **installable release** for a test environment, not a cloud deployment.

---

## Delivery Phases

1. **Phase 0** — Scope and environment lock
2. **Phase 1** — MVP foundation
3. **Phase 2** — First installable demo release
4. **Phase 3** — P1 business scenarios
5. **Separate backlog** — post-demo and advanced capabilities

---

## Parallel Workstreams (first 3–4 weeks)

```text
Week 1–2:
  Lane A (Architecture/Platform): PRE-01 → PRE-03 → PRE-04 → PRE-05
  Lane B (Backend):               BE-01 → BE-02 → BE-03 → BE-04 → BE-05
  Lane C (Data):                  PRE-02 → ING-01 → ING-02 → ING-03
  Lane D (Frontend):              FE-01 → FE-02 → FE-03 → FE-04

Week 2–3:
  Lane A:                         BE-06 → BE-07 → BE-08
  Lane B:                         BE-09 → BE-10 → BE-11
  Lane C:                         ING-04 → ING-05
  Lane D:                         FE-05 → REL-01

Week 3–4:
  Shared:                         REL-02 → REL-03 → QA-01
  Next wave:                      IR-01 → IR-02 → IR-03 / ING-06 → ING-07 / FE-06 → FE-07 → QA-02
```

---

## Phase 0 — Scope and Environment Lock

| ID | Task | Priority | Estimate | Dependencies | Details |
|----|------|----------|----------|--------------|---------|
| PRE-01 | **Define Priority-1 connectors for VZ** | P0 | 1d | — | Lock the connector scope that must be ready for the first real scenario. |
| PRE-02 | **Define Priority-1 charts and dashboards** | P0 | 1d | — | Agree which user scenarios must be demonstrable in the first release. |
| PRE-03 | **Stand up test ClickHouse** | P0 | 1d | — | Shared environment for ingestion and analytics work. |
| PRE-04 | **Stand up test auxiliary services** | P0 | 1–2d | PRE-03 | Airbyte and any other third-party services required for ingestion/backend verification. |
| PRE-05 | **Decide v0.1 release boundary** | P0 | 1d | PRE-03, PRE-04 | Record what the installer provisions directly and what remains an external test dependency. |

---

## Phase 1 — MVP Foundation

### Backend

| ID | Task | Priority | Estimate | Dependencies | Details |
|----|------|----------|----------|--------------|---------|
| BE-01 | **ClickHouse connection pool & config** | P0 | 1–2d | — | Shared Rust crate. Configurable connection pool with timeouts, health-check ping, config via env vars. |
| BE-02 | **Parameterized query builder** | P0 | 1–2d | BE-01 | Bind-parameter-only queries, tenant scoping, query timeout enforcement. |
| BE-03 | **OData-to-ClickHouse SQL translator + client tests** | P0 | 2–3d | BE-02 | Translate `$filter`, `$orderby`, `$select`, `$top`, `$skip` and cover safety/tenant-isolation behavior with tests. |
| BE-04 | **Identity Service skeleton + MariaDB schema** | P0 | 2d | — | Service scaffold with cyberfabric-core, migrations, health/readiness endpoints. |
| BE-05 | **Org hierarchy + membership CRUD** | P0 | 2d | BE-04 | Org tree, temporal memberships, and integrity validation. |
| BE-06 | **OIDC subject mapping + RBAC role CRUD** | P0 | 1–2d | BE-05 | First-login auto-create flow, `persons/me`, and baseline role assignment APIs. |
| BE-07 | **Authz plugin: RBAC permission check + org-tree scoping** | P0 | 2d | BE-06 | Implement two-layer authorization and return scoped evaluation constraints. |
| BE-08 | **Authz plugin: Redis caching + integration tests** | P0 | 1–2d | BE-07 | Cache computed scopes and verify role/scope behavior end-to-end. |
| BE-09 | **Analytics API skeleton + MariaDB schema** | P0 | 1–2d | BE-04 (pattern) | Service scaffold for metrics and dashboards with health/readiness endpoints. |
| BE-10 | **Analytics query endpoint with authz scoping** | P0 | 2–3d | BE-03, BE-08, BE-09 | Core e2e data path from OData filters to ClickHouse results. |
| BE-11 | **Metrics catalog CRUD** | P0 | 2d | BE-09 | Store and manage metric definitions required by the first dashboards. |

---

## Ingestion / Data Engineering Tasks

### Data / Ingestion

| ID | Task | Priority | Estimate | Dependencies | Details |
|----|------|----------|----------|--------------|---------|
| ING-01 | **Review approved Priority-1 connectors vs latest specs** | P0 | 2d | PRE-01 | Audit only the approved first-wave connectors and document gaps. |
| ING-02 | **Review and normalize Silver layer descriptions** | P0 | 1–2d | PRE-01 | Validate the target Silver schemas required by the first release scenarios. |
| ING-03 | **dbt bronze→silver for first approved connectors** | P0 | 2d | ING-01, ING-02 | Implement the first batch of connector transforms with tests. |
| ING-04 | **dbt bronze→silver for remaining approved connectors** | P0 | 2d | ING-03 | Finish the P1 connector subset without broadening scope beyond the approved list. |
| ING-05 | **Test ingestion pipeline into ClickHouse** | P0 | 2d | PRE-03, PRE-04, ING-04 | Run Airbyte + dbt in the test environment and verify data reaches expected Silver tables. |

---

## Frontend Tasks

### Frontend

| ID | Task | Priority | Estimate | Dependencies | Details |
|----|------|----------|----------|--------------|---------|
| FE-01 | **Frontend skeleton on frontx** | P0 | 2d | — | Scaffold the UI app, tooling, folder structure, and backend proxy setup. |
| FE-02 | **OIDC login integration** | P0 | 2d | FE-01 | Login redirect/callback flow, token handling, logout. |
| FE-03 | **API client layer** | P0 | 1–2d | FE-01 | Centralized auth-aware HTTP client and API models. |
| FE-04 | **App shell: routing, navigation, session guards** | P0 | 1–2d | FE-02, FE-03 | Minimal shell needed to wire login and the first dashboard scenario. |

---

## Phase 2 — First Installable Demo Release

### Backend

| ID | Task | Priority | Estimate | Dependencies | Details |
|----|------|----------|----------|--------------|---------|
| BE-12 | **Dashboard config CRUD** | P1 | 2d | BE-09 | Persist dashboard layout/config once the live query path is working. |

### Frontend

| ID | Task | Priority | Estimate | Dependencies | Details |
|----|------|----------|----------|--------------|---------|
| FE-05 | **Minimal dashboard viewer with live data** | P0 | 2–3d | FE-04, BE-10, BE-11 | First demonstrable UI path for metrics and charts; keep editing scope intentionally small. |

### Release / Installation

| ID | Task | Priority | Estimate | Dependencies | Details |
|----|------|----------|----------|--------------|---------|
| REL-01 | **Helm release skeleton with core dependencies** | P0 | 2d | PRE-05, BE-04, BE-09 | On-prem installer baseline. Provision ClickHouse, MariaDB, and Redis for the release. |
| REL-02 | **Service manifests, migrations, ingress/TLS, secrets, bootstrap seed** | P0 | 2d | REL-01, BE-10 | Make backend services installable with migrations and initial seed data. |
| REL-03 | **Frontend packaging and inclusion in installer** | P0 | 1d | FE-05, REL-02 | Package static assets and wire the frontend into the release installer. |

### Validation

| ID | Task | Priority | Estimate | Dependencies | Details |
|----|------|----------|----------|--------------|---------|
| QA-01 | **First end-to-end test installation** | P0 | 1–2d | ING-05, BE-10, FE-05, REL-03 | Validate the first installable demo scenario end-to-end in a test environment. |

---

## Phase 3 — P1 Business Scenarios

| ID | Task | Priority | Estimate | Dependencies | Details |
|----|------|----------|----------|--------------|---------|
| IR-01 | **Choose base HR system and define canonical person model** | P1 | 1d | PRE-01, PRE-02 | Decide source of truth and define `class_people` / final identity contract. |
| IR-02 | **Identity Resolution core: skeleton, alias matching, golden record builder, bootstrap** | P1 | 2–3d | BE-01, BE-04, IR-01 | Core identity-resolution behavior from the backend decomposition. |
| IR-03 | **Write `person_id` to Silver step 2 and integrate with connector outputs** | P1 | 2d | IR-02, ING-05 | Produce analytics-ready identity-enriched data. |
| ING-06 | **dbt support for identity resolution** | P1 | 2–3d | ING-04, IR-01 | Build `class_people` and supporting transforms. |
| ING-07 | **Gold / materialized views for approved P1 charts** | P1 | 2–3d | PRE-02, ING-05 | Shape data for the first real dashboard scenarios. |
| FE-06 | **Implement approved P1 charts and dashboards** | P1 | 2–3d | FE-05, BE-12, ING-07 | Build only the agreed first-scenario visualizations. |
| FE-07 | **Chart polish and error/debug UX** | P1 | 1–2d | FE-06 | Improve loading, empty-state, and malformed-data handling during connector refinement. |
| QA-02 | **Backend/UI tests, data-format debugging, performance checks** | P1 | 2d | IR-03, FE-06 | Cover the first real business scenarios with automated and manual validation. |

---

## Separate Backlog — Not on Critical Path

| ID | Task | Priority | Estimate | Dependencies | Details |
|----|------|----------|----------|--------------|---------|
| BL-01 | **Connector refinement backlog beyond approved P1 scope** | P2 | ongoing | PRE-01 | Keep non-P1 connector work separate from the demo critical path. |
| BL-02 | **Connector Manager service** | P2 | 2–3d | REL-02 | CRUD, Airbyte integration, sync monitoring, credential handling. |
| BL-03 | **Connector management UI** | P2 | 2–3d | BL-02 | Admin UX for connector setup and sync control. |
| BL-04 | **Transform Service** | P2 | 2–3d | BL-02 | Manage Silver/Gold transform rules and run orchestration. |
| BL-05 | **Audit Trail / Redpanda-based async flows** | P2 | 2–3d | BE-01 | Audit events and async backbone from decomposition v0.5. |
| BL-06 | **Org sync + alerts + email** | P2 | 2–3d | BL-05 | Automated org sync, business alerts, email delivery. |
| BL-07 | **Production hardening** | P2 | 2–3d | BL-05, BL-06 | Observability, CSV export, cache invalidation, advanced Helm features. |
| BL-08 | **Advanced constructor (custom dashboards/charts/connectors)** | P3 | 2–3d | FE-06, BL-04 | Future self-service customization. |

---

## Summary: Critical Path to First Installable Demo Release

```text
Parallel start:
  PRE-01 / PRE-02 / PRE-03 / PRE-04 / PRE-05
  BE-01 → BE-02 → BE-03
  BE-04 → BE-05 → BE-06 → BE-07 → BE-08
  BE-09 → BE-10 → BE-11
  ING-01 → ING-02 → ING-03 → ING-04 → ING-05
  FE-01 → FE-02 → FE-03 → FE-04 → FE-05

Converge:
  REL-01 → REL-02 → REL-03
  QA-01

Meaningful demo with real scenarios:
  IR-01 → IR-02 → IR-03
  ING-06 → ING-07
  FE-06 → FE-07
  QA-02
```

**P0 themes**: prerequisites, MVP foundation, release packaging, first e2e install test  
**P1 themes**: identity-enriched data, Gold views, approved charts/dashboards, scenario validation

---

## GitHub Project Labels

Suggested labels for filtering:

| Label | Color | Description |
|-------|-------|-------------|
| `team:backend` | blue | Backend Rust services |
| `team:frontend` | green | Frontend (frontx) |
| `team:data` | orange | Ingestion and dbt |
| `team:platform` | teal | Release packaging, Helm, environments |
| `team:qa` | pink | Test installation and scenario validation |
| `priority:P0` | red | Critical path — blocks first installable release |
| `priority:P1` | yellow | Meaningful demo features |
| `priority:P2` | grey | Second wave |
| `priority:P3` | white | Hardening & advanced |
| `phase:0` | brown | Scope and environment lock |
| `phase:1` | brown | MVP foundation |
| `phase:2` | brown | First installable demo release |
| `phase:3` | brown | P1 business scenarios |
| `phase:backlog` | brown | Separate backlog |
| `component:clickhouse-client` | purple | Shared ClickHouse crate |
| `component:identity-service` | purple | Identity Service |
| `component:authz-plugin` | purple | Authz Plugin |
| `component:analytics-api` | purple | Analytics API |
| `component:release-installer` | purple | Helm chart / release installer |
| `component:identity-resolution` | purple | Identity Resolution |
| `component:ingestion` | purple | dbt / approved connector scope |
| `component:frontend` | purple | UI app |
