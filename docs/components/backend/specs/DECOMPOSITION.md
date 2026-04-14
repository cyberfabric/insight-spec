---
status: proposed
date: 2026-04-02
---

# Decomposition: Backend

<!-- toc -->

- [1. Overview](#1-overview)
- [2. Entries](#2-entries)
  - [2.1 Shared ClickHouse Client - CRITICAL](#21-shared-clickhouse-client---critical)
  - [2.2 Identity Service - CRITICAL](#22-identity-service---critical)
  - [2.3 Authz Plugin - CRITICAL](#23-authz-plugin---critical)
  - [2.4 Analytics API - CRITICAL](#24-analytics-api---critical)
  - [2.5 Minimal Helm Chart - CRITICAL](#25-minimal-helm-chart---critical)
  - [2.6 Identity Resolution Service - HIGH](#26-identity-resolution-service---high)
  - [2.7 Connector Manager - HIGH](#27-connector-manager---high)
  - [2.8 Transform Service - MEDIUM](#28-transform-service---medium)
  - [2.9 Audit Trail - MEDIUM](#29-audit-trail---medium)
  - [2.10 Org Sync + Alerts + Email - MEDIUM](#210-org-sync--alerts--email---medium)
  - [2.11 Production Hardening - MEDIUM](#211-production-hardening---medium)
- [3. Feature Dependencies](#3-feature-dependencies)

<!-- /toc -->

## 1. Overview

The Backend DESIGN defines 8 microservices, 1 custom authz plugin, 4 shared crates, and infrastructure (Helm, ArgoCD). This decomposition maps those components to implementation features ordered by the [PLAN.md](../PLAN.md) delivery roadmap (v0.1-v0.7).

Decomposition strategy: **one feature per service or shared crate**, grouped by delivery version. Each feature is independently implementable and testable. Dependencies between features are explicit — no feature starts until its dependencies are marked complete.

Features reference DESIGN component IDs (`cpt-insightspec-component-be-*`) and PRD requirement IDs (`cpt-insightspec-fr-be-*`, `cpt-insightspec-nfr-be-*`).

## 2. Entries

**Overall implementation status:**

- [ ] `p1` - **ID**: `cpt-insightspec-status-be-overall`

---

### 2.1 Shared ClickHouse Client - CRITICAL

- [ ] `p1` - **ID**: `cpt-insightspec-feature-clickhouse-client`

- **Purpose**: Shared crate providing ClickHouse connection pool, parameterized query builder, and OData-to-ClickHouse SQL translation. Foundation for Analytics API, Alerts Service, Audit Service, and Identity Resolution Service.

- **Depends On**: None

- **Version**: v0.1

- **Scope**:
  - Connection pool with configurable timeouts
  - Parameterized query builder (bind parameters only, no string interpolation)
  - OData $filter/$orderby/$select to ClickHouse SQL translation
  - Query timeout enforcement
  - Tenant_id scoping on all queries

- **Out of scope**:
  - Write operations (inserts handled per-service)
  - Schema management (ClickHouse tables managed by ingestion layer)

- **Requirements Covered**:

  - [ ] `p1` - `cpt-insightspec-nfr-be-query-safety`
  - [ ] `p1` - `cpt-insightspec-nfr-be-tenant-isolation`

- **Design Principles Covered**:

  - [ ] `p1` - `cpt-insightspec-principle-be-secure-by-default`

- **Design Constraints Covered**:

  - [ ] `p1` - `cpt-insightspec-constraint-be-cyberfabric-core`

- **Domain Model Entities**:
  - None (infrastructure crate)

- **Design Components**:

  - [ ] `p1` - `cpt-insightspec-component-be-analytics-api` (consumer)
  - [ ] `p1` - `cpt-insightspec-component-be-audit-service` (consumer)
  - [ ] `p1` - `cpt-insightspec-component-be-alerts-service` (consumer)
  - [ ] `p1` - `cpt-insightspec-component-be-identity-resolution` (consumer)

- **API**:
  - Internal Rust API only (no HTTP endpoints)

- **Sequences**:

  - `cpt-insightspec-seq-analytics-query` (used by)

- **Data**:
  - ClickHouse Silver/Gold tables (read-only)

---

### 2.2 Identity Service - CRITICAL

- [ ] `p1` - **ID**: `cpt-insightspec-feature-identity-service`

- **Purpose**: Manages organizational hierarchy, person-org memberships with temporal validity, OIDC-to-person_id mapping, and RBAC role assignments. Provides the access scope data that the authz plugin uses for every request.

- **Depends On**: None

- **Version**: v0.1

- **Scope**:
  - Org unit CRUD (tree structure with parent_id)
  - Person-org membership CRUD with effective_from/effective_to
  - OIDC subject to person_id mapping (first-login auto-create)
  - RBAC role assignment CRUD (5 roles)
  - MariaDB schema and migrations
  - Org tree seeded via migration script (manual; auto-sync deferred to v0.6)

- **Out of scope**:
  - HR/directory auto-sync (v0.6)
  - Pluggable source adapters (v0.6)

- **Requirements Covered**:

  - [ ] `p1` - `cpt-insightspec-fr-be-org-tree-sync` (partial — CRUD only, no auto-sync)
  - [ ] `p1` - `cpt-insightspec-fr-be-identity-resolution` (OIDC mapping)
  - [ ] `p1` - `cpt-insightspec-fr-be-rbac`
  - [ ] `p1` - `cpt-insightspec-fr-be-visibility-policy`
  - [ ] `p1` - `cpt-insightspec-fr-be-forward-only-migrations`
  - [ ] `p1` - `cpt-insightspec-fr-be-migration-on-startup`

- **Design Principles Covered**:

  - [ ] `p1` - `cpt-insightspec-principle-be-service-owns-data`
  - [ ] `p1` - `cpt-insightspec-principle-be-two-layer-authz`
  - [ ] `p1` - `cpt-insightspec-principle-be-follow-unit-strict`

- **Design Constraints Covered**:

  - [ ] `p1` - `cpt-insightspec-constraint-be-oidc-only`
  - [ ] `p1` - `cpt-insightspec-constraint-be-cyberfabric-core`

- **Domain Model Entities**:
  - OrgUnit
  - PersonOrgMembership
  - UserIdentity
  - UserRole

- **Design Components**:

  - [ ] `p1` - `cpt-insightspec-component-be-identity-service`

- **API**:
  - GET /api/v1/identity/org-units
  - GET /api/v1/identity/org-units/{id}
  - GET /api/v1/identity/org-units/{id}/members
  - GET /api/v1/identity/persons/{id}
  - GET /api/v1/identity/persons/me
  - GET /api/v1/identity/roles
  - POST /api/v1/identity/roles
  - DELETE /api/v1/identity/roles/{id}

- **Sequences**:

  - `cpt-insightspec-seq-first-login`

- **Data**:
  - MariaDB: org_units, person_org_membership, user_identities, user_roles

---

### 2.3 Authz Plugin - CRITICAL

- [ ] `p1` - **ID**: `cpt-insightspec-feature-authz-plugin`

- **Purpose**: Custom authz-resolver plugin implementing two-layer authorization: RBAC permission check + org-tree data scoping with temporal constraints. Without this, no data visibility control is possible.

- **Depends On**: `cpt-insightspec-feature-identity-service`

- **Version**: v0.1

- **Scope**:
  - Implement AuthZResolverPluginClient trait
  - Step 1: RBAC lookup (user_roles table) → permission decision
  - Step 2: Org-tree lookup (person_org_membership) → In constraints on org_unit_id + time ranges
  - Return EvaluationResponse with constraints
  - Redis caching of computed access scopes (with TTL)

- **Out of scope**:
  - Event-driven cache invalidation (v0.5, requires Redpanda)

- **Requirements Covered**:

  - [ ] `p1` - `cpt-insightspec-fr-be-rbac`
  - [ ] `p1` - `cpt-insightspec-fr-be-visibility-policy`
  - [ ] `p1` - `cpt-insightspec-nfr-be-tenant-isolation`

- **Design Principles Covered**:

  - [ ] `p1` - `cpt-insightspec-principle-be-two-layer-authz`
  - [ ] `p1` - `cpt-insightspec-principle-be-follow-unit-strict`
  - [ ] `p1` - `cpt-insightspec-principle-be-secure-by-default`

- **Design Constraints Covered**:

  - [ ] `p1` - `cpt-insightspec-constraint-be-cyberfabric-core`

- **Domain Model Entities**:
  - UserRole (read)
  - PersonOrgMembership (read)
  - OrgUnit (read)

- **Design Components**:

  - [ ] `p1` - `cpt-insightspec-component-be-authz-plugin`

- **API**:
  - Internal: AuthZResolverPluginClient.evaluate(EvaluationRequest) → EvaluationResponse

- **Sequences**:

  - `cpt-insightspec-seq-analytics-query` (step: authz evaluation)

- **Data**:
  - Reads from Identity Service MariaDB (user_roles, person_org_membership)
  - Redis: cached access scopes

---

### 2.4 Analytics API - CRITICAL

- [ ] `p1` - **ID**: `cpt-insightspec-feature-analytics-api`

- **Purpose**: Core user-facing service. Serves analytics data from ClickHouse, manages metrics catalog and dashboard configurations. The service users interact with most.

- **Depends On**: `cpt-insightspec-feature-clickhouse-client`, `cpt-insightspec-feature-authz-plugin`

- **Version**: v0.1

- **Scope**:
  - ClickHouse read queries with OData filtering, scoped by authz constraints
  - Metrics catalog CRUD (MariaDB)
  - Dashboard/chart config CRUD (MariaDB)
  - MariaDB schema and migrations

- **Out of scope**:
  - CSV export (v0.7)
  - Cache invalidation via Redpanda (v0.5)

- **Requirements Covered**:

  - [ ] `p1` - `cpt-insightspec-fr-be-analytics-read`
  - [ ] `p1` - `cpt-insightspec-fr-be-metrics-catalog`
  - [ ] `p1` - `cpt-insightspec-fr-be-dashboard-config`
  - [ ] `p1` - `cpt-insightspec-nfr-be-api-conventions`
  - [ ] `p1` - `cpt-insightspec-nfr-be-api-versioning`
  - [ ] `p1` - `cpt-insightspec-nfr-be-rate-limiting`

- **Design Principles Covered**:

  - [ ] `p1` - `cpt-insightspec-principle-be-service-owns-data`
  - [ ] `p1` - `cpt-insightspec-principle-be-api-versioned`

- **Design Constraints Covered**:

  - [ ] `p1` - `cpt-insightspec-constraint-be-cyberfabric-core`

- **Domain Model Entities**:
  - Metric
  - Dashboard

- **Design Components**:

  - [ ] `p1` - `cpt-insightspec-component-be-analytics-api`

- **API**:
  - GET /api/v1/analytics/metrics
  - POST /api/v1/analytics/metrics
  - GET /api/v1/analytics/metrics/{id}
  - PUT /api/v1/analytics/metrics/{id}
  - DELETE /api/v1/analytics/metrics/{id}
  - POST /api/v1/analytics/metrics/query
  - GET /api/v1/analytics/dashboards
  - POST /api/v1/analytics/dashboards
  - GET /api/v1/analytics/dashboards/{id}
  - PUT /api/v1/analytics/dashboards/{id}
  - DELETE /api/v1/analytics/dashboards/{id}

- **Sequences**:

  - `cpt-insightspec-seq-analytics-query`

- **Data**:
  - ClickHouse Silver/Gold (read-only)
  - MariaDB: metrics, dashboards

---

### 2.5 Minimal Helm Chart - CRITICAL

- [ ] `p1` - **ID**: `cpt-insightspec-feature-helm-minimal`

- **Purpose**: Deploy MVP services on Kubernetes. Minimal chart with only what v0.1 needs.

- **Depends On**: `cpt-insightspec-feature-analytics-api`, `cpt-insightspec-feature-identity-service`

- **Version**: v0.1

- **Scope**:
  - Analytics API deployment + service + migration job
  - Identity Service deployment + service + migration job
  - MariaDB subchart (init script creates per-service DBs)
  - Redis subchart
  - Ingress with TLS
  - Sealed Secrets for OIDC config
  - Bootstrap: root tenant + initial Tenant Admin seeded from Helm values

- **Out of scope**:
  - Redpanda, MinIO, Airbyte, Kestra subcharts (pre-existing, not managed by this chart)
  - HPA, observability stack (v0.7)

- **Requirements Covered**:

  - [ ] `p1` - `cpt-insightspec-fr-be-oidc-auth`
  - [ ] `p1` - `cpt-insightspec-fr-be-health-checks`
  - [ ] `p1` - `cpt-insightspec-fr-be-migration-on-startup`

- **Design Principles Covered**:

  - [ ] `p1` - `cpt-insightspec-principle-be-api-versioned`

- **Design Constraints Covered**:

  - [ ] `p1` - `cpt-insightspec-constraint-be-standalone`

- **Domain Model Entities**:
  - Tenant (bootstrap seed)

- **Design Components**:

  - [ ] `p1` - `cpt-insightspec-component-be-analytics-api` (deployment)
  - [ ] `p1` - `cpt-insightspec-component-be-identity-service` (deployment)

- **API**:
  - /health, /ready (per service)

- **Sequences**:
  - None

- **Data**:
  - MariaDB init script (per-service DBs)

---

### 2.6 Identity Resolution Service - HIGH

- [ ] `p1` - **ID**: `cpt-insightspec-feature-identity-resolution`

- **Purpose**: Maps disparate identity signals from multiple sources into canonical person records. Enables cross-source analytics. Phase 1: shared ClickHouse tables (DD-BE-01).

- **Depends On**: `cpt-insightspec-feature-clickhouse-client`, `cpt-insightspec-feature-identity-service`

- **Version**: v0.2

- **Scope**:
  - Alias matching (email, username, employee ID)
  - Golden record builder
  - Merge/split operations with audit trail
  - Bootstrap job (seed from class_people Silver table)
  - Resolution service (write person_id into Silver step 2)
  - Conflict detection and manual override API
  - MariaDB schema (alias mappings, golden records, merge history)
  - Phase 1 integration: Analytics API reads Silver step 2 directly from ClickHouse

- **Out of scope**:
  - Phase 2 REST API enrichment (v0.3+, per DD-BE-01)
  - Automated GDPR erasure (v1.0+; manual scripts supported)

- **Requirements Covered**:

  - [ ] `p1` - `cpt-insightspec-fr-be-identity-resolution-service`

- **Design Principles Covered**:

  - [ ] `p1` - `cpt-insightspec-principle-be-service-owns-data`

- **Design Constraints Covered**:

  - [ ] `p1` - `cpt-insightspec-constraint-be-cyberfabric-core`

- **Domain Model Entities**:
  - Person
  - UserIdentity (alias mappings)

- **Design Components**:

  - [ ] `p1` - `cpt-insightspec-component-be-identity-resolution`

- **API**:
  - GET /api/v1/identity-resolution/persons
  - GET /api/v1/identity-resolution/persons/{id}
  - GET /api/v1/identity-resolution/persons/{id}/aliases
  - POST /api/v1/identity-resolution/persons/merge
  - POST /api/v1/identity-resolution/persons/split
  - GET /api/v1/identity-resolution/conflicts
  - POST /api/v1/identity-resolution/conflicts/{id}/resolve
  - POST /api/v1/identity-resolution/bootstrap/trigger
  - GET /api/v1/identity-resolution/bootstrap/status

- **Sequences**:
  - None defined in DESIGN (add during implementation)

- **Data**:
  - MariaDB: alias_mappings, golden_records, merge_history
  - ClickHouse: Silver step 1 (read), Silver step 2 (write person_id)

---

### 2.7 Connector Manager - HIGH

- [ ] `p1` - **ID**: `cpt-insightspec-feature-connector-manager`

- **Purpose**: Manages data source configurations, encrypted credentials, and Airbyte connections. Replaces manual Airbyte configuration.

- **Depends On**: `cpt-insightspec-feature-helm-minimal`

- **Version**: v0.3

- **Scope**:
  - Connector config CRUD (MariaDB)
  - Airbyte API integration (create, update, trigger sync, delete connections)
  - Sync status monitoring
  - Envelope encryption for credentials (per-tenant DEK/KEK, AES-256-GCM)
  - MariaDB schema (connector_configs, tenant_keys, secrets)

- **Out of scope**:
  - Connector status events via Redpanda (v0.5)

- **Requirements Covered**:

  - [ ] `p1` - `cpt-insightspec-fr-be-connector-crud`
  - [ ] `p1` - `cpt-insightspec-fr-be-secret-management`

- **Design Principles Covered**:

  - [ ] `p1` - `cpt-insightspec-principle-be-service-owns-data`
  - [ ] `p1` - `cpt-insightspec-principle-be-secure-by-default`

- **Design Constraints Covered**:

  - [ ] `p1` - `cpt-insightspec-constraint-be-cyberfabric-core`

- **Domain Model Entities**:
  - ConnectorConfig
  - TenantKey
  - Secret

- **Design Components**:

  - [ ] `p1` - `cpt-insightspec-component-be-connector-manager`

- **API**:
  - GET /api/v1/connectors/connections
  - POST /api/v1/connectors/connections
  - GET /api/v1/connectors/connections/{id}
  - PUT /api/v1/connectors/connections/{id}
  - DELETE /api/v1/connectors/connections/{id}
  - POST /api/v1/connectors/connections/{id}/sync
  - GET /api/v1/connectors/connections/{id}/status
  - GET /api/v1/connectors/connections/{id}/secrets
  - PUT /api/v1/connectors/connections/{id}/secrets/{key}
  - DELETE /api/v1/connectors/connections/{id}/secrets/{key}

- **Sequences**:
  - None defined in DESIGN (add during implementation)

- **Data**:
  - MariaDB: connector_configs, tenant_keys, secrets

---

### 2.8 Transform Service - MEDIUM

- [ ] `p2` - **ID**: `cpt-insightspec-feature-transform-service`

- **Purpose**: Manages dbt transform rules, Silver/Gold table configurations, dependency graph, and triggers pipeline runs via orchestrator API.

- **Depends On**: `cpt-insightspec-feature-connector-manager`

- **Version**: v0.4

- **Scope**:
  - Silver transform rules CRUD (Bronze → Silver mappings, union rules)
  - Gold metric rules CRUD (Silver → Gold aggregations)
  - Dependency graph (which connectors feed which transforms)
  - Trigger pipeline runs via orchestrator API
  - Run status monitoring
  - MariaDB schema (silver_rules, gold_rules, dependencies, run_history)

- **Out of scope**:
  - Transform status events via Redpanda (v0.5)

- **Requirements Covered**:

  - [ ] `p1` - `cpt-insightspec-fr-be-transform-rules`

- **Design Principles Covered**:

  - [ ] `p1` - `cpt-insightspec-principle-be-service-owns-data`

- **Design Constraints Covered**:

  - [ ] `p1` - `cpt-insightspec-constraint-be-cyberfabric-core`

- **Domain Model Entities**:
  - None in DESIGN domain model (transform-specific entities defined during implementation)

- **Design Components**:

  - [ ] `p1` - `cpt-insightspec-component-be-transform-service`

- **API**:
  - GET /api/v1/transforms/silver-rules
  - POST /api/v1/transforms/silver-rules
  - GET /api/v1/transforms/silver-rules/{id}
  - PUT /api/v1/transforms/silver-rules/{id}
  - DELETE /api/v1/transforms/silver-rules/{id}
  - GET /api/v1/transforms/gold-rules
  - POST /api/v1/transforms/gold-rules
  - GET /api/v1/transforms/gold-rules/{id}
  - PUT /api/v1/transforms/gold-rules/{id}
  - DELETE /api/v1/transforms/gold-rules/{id}
  - GET /api/v1/transforms/dependencies
  - POST /api/v1/transforms/runs/trigger
  - GET /api/v1/transforms/runs/{id}/status

- **Sequences**:
  - None defined in DESIGN (add during implementation)

- **Data**:
  - MariaDB: silver_rules, gold_rules, dependencies, run_history

---

### 2.9 Audit Trail - MEDIUM

- [ ] `p2` - **ID**: `cpt-insightspec-feature-audit-trail`

- **Purpose**: Compliance audit trail. Includes shared Redpanda crate (foundation for all async flows), audit event publisher (retrofit into all services), and Audit Service (consume + store + query).

- **Depends On**: `cpt-insightspec-feature-clickhouse-client`

- **Version**: v0.5

- **Scope**:
  - insight-redpanda shared crate (producer/consumer setup, topic constants, message envelopes)
  - insight-audit-client shared crate (lightweight publisher, retrofit into all existing services)
  - Audit Service: consume from Redpanda, store in ClickHouse, query API with OData
  - ClickHouse audit table (MergeTree, monthly partitions, TTL)
  - Redpanda subchart added to Helm
  - Retrofit audit event emission into Analytics API, Identity Service, Connector Manager, Transform Service, Identity Resolution Service

- **Out of scope**:
  - Cache invalidation via Redpanda (v0.7)
  - Email request publishing (v0.6)

- **Requirements Covered**:

  - [ ] `p1` - `cpt-insightspec-fr-be-audit-trail`
  - [ ] `p1` - `cpt-insightspec-nfr-be-api-conventions`

- **Design Principles Covered**:

  - [ ] `p1` - `cpt-insightspec-principle-be-event-driven`

- **Design Constraints Covered**:

  - [ ] `p1` - `cpt-insightspec-constraint-be-redpanda`

- **Domain Model Entities**:
  - AuditEvent

- **Design Components**:

  - [ ] `p2` - `cpt-insightspec-component-be-audit-service`

- **API**:
  - GET /api/v1/audit/events (OData filtering)

- **Sequences**:
  - None defined in DESIGN (add during implementation)

- **Data**:
  - ClickHouse: insight_audit.events
  - Redpanda: insight.audit.events topic

---

### 2.10 Org Sync + Alerts + Email - MEDIUM

- [ ] `p2` - **ID**: `cpt-insightspec-feature-org-alerts-email`

- **Purpose**: Automated org tree sync from HR/directory systems. Business alerts with email notifications. Centralized email delivery. Also includes insight-retry shared crate.

- **Depends On**: `cpt-insightspec-feature-identity-service`, `cpt-insightspec-feature-audit-trail`

- **Version**: v0.6

- **Scope**:
  - Identity Service: pluggable HR/directory sync adapters (AD/LDAP, BambooHR API, Workday API), scheduled background sync, leader election for sync singleton
  - Alerts Service: alert rule CRUD, periodic ClickHouse threshold evaluation, publish email requests to Redpanda
  - Email Service: consume from Redpanda, render templates, SMTP delivery with retries, delivery tracking
  - insight-retry shared crate (exponential backoff with jitter, retrofit into all services)
  - MariaDB schemas for Alerts (rules, history) and Email (templates, delivery log)

- **Out of scope**:
  - Alert escalation policies (future)

- **Requirements Covered**:

  - [ ] `p1` - `cpt-insightspec-fr-be-org-tree-sync` (full — auto-sync)
  - [ ] `p2` - `cpt-insightspec-fr-be-business-alerts`
  - [ ] `p2` - `cpt-insightspec-fr-be-email-delivery`
  - [ ] `p2` - `cpt-insightspec-nfr-be-retry-resilience`

- **Design Principles Covered**:

  - [ ] `p1` - `cpt-insightspec-principle-be-event-driven`

- **Design Constraints Covered**:

  - [ ] `p1` - `cpt-insightspec-constraint-be-redpanda`

- **Domain Model Entities**:
  - AlertRule
  - OrgUnit (sync updates)
  - PersonOrgMembership (sync updates)

- **Design Components**:

  - [ ] `p1` - `cpt-insightspec-component-be-identity-service` (HR sync extension)
  - [ ] `p2` - `cpt-insightspec-component-be-alerts-service`
  - [ ] `p2` - `cpt-insightspec-component-be-email-service`

- **API**:
  - POST /api/v1/identity/sync/trigger
  - GET /api/v1/alerts/rules
  - POST /api/v1/alerts/rules
  - GET /api/v1/alerts/rules/{id}
  - PUT /api/v1/alerts/rules/{id}
  - DELETE /api/v1/alerts/rules/{id}
  - GET /api/v1/alerts/history
  - POST /api/v1/alerts/history/{id}/acknowledge

- **Sequences**:

  - `cpt-insightspec-seq-alert-evaluation`

- **Data**:
  - MariaDB: alert_rules, alert_history, email_templates, email_delivery_log
  - Redpanda: insight.email.requests, insight.alerts.fired topics

---

### 2.11 Production Hardening - MEDIUM

- [ ] `p2` - **ID**: `cpt-insightspec-feature-production-hardening`

- **Purpose**: Production readiness: CSV export, observability, caching with event-driven invalidation, full Helm charts, ArgoCD deployment.

- **Depends On**: `cpt-insightspec-feature-audit-trail`, `cpt-insightspec-feature-org-alerts-email`

- **Version**: v0.7

- **Scope**:
  - CSV export: build query results as CSV, store on S3 (MinIO), return download link, 1-week expiry
  - Observability: Prometheus + Grafana + Alertmanager + Loki subcharts
  - Redis caching: cache authz scopes, metrics catalog, identity mappings + Redpanda-based invalidation
  - Health/readiness endpoints for all services
  - Full Helm charts per service: HPA, sealed secrets, migration jobs
  - MinIO subchart for S3
  - ArgoCD Application manifests, sync waves, image updater

- **Out of scope**:
  - Dashboard sharing (v1.0+)
  - PDF reports (v1.0+)
  - Public analytics API (v1.0+)

- **Requirements Covered**:

  - [ ] `p2` - `cpt-insightspec-fr-be-csv-export`
  - [ ] `p1` - `cpt-insightspec-fr-be-health-checks`
  - [ ] `p2` - `cpt-insightspec-nfr-be-rate-limiting`
  - [ ] `p2` - `cpt-insightspec-nfr-be-graceful-shutdown`

- **Design Principles Covered**:

  - [ ] `p1` - `cpt-insightspec-principle-be-api-versioned`

- **Design Constraints Covered**:

  - [ ] `p1` - `cpt-insightspec-constraint-be-standalone`

- **Domain Model Entities**:
  - None (cross-cutting infrastructure)

- **Design Components**:

  - [ ] `p1` - `cpt-insightspec-component-be-analytics-api` (CSV export extension)

- **API**:
  - POST /api/v1/analytics/metrics/export
  - GET /api/v1/analytics/exports/{id}
  - /health, /ready (all services)

- **Sequences**:
  - None

- **Data**:
  - S3 (MinIO): CSV exports with lifecycle policy
  - Redis: cached access scopes, metrics catalog

---

## 3. Feature Dependencies

```text
cpt-insightspec-feature-clickhouse-client (v0.1)
    ↓
    ├─→ cpt-insightspec-feature-analytics-api (v0.1)
    ├─→ cpt-insightspec-feature-identity-resolution (v0.2)
    └─→ cpt-insightspec-feature-audit-trail (v0.5)

cpt-insightspec-feature-identity-service (v0.1)
    ↓
    ├─→ cpt-insightspec-feature-authz-plugin (v0.1)
    ├─→ cpt-insightspec-feature-identity-resolution (v0.2)
    └─→ cpt-insightspec-feature-org-alerts-email (v0.6)

cpt-insightspec-feature-authz-plugin (v0.1)
    ↓
    └─→ cpt-insightspec-feature-analytics-api (v0.1)

cpt-insightspec-feature-analytics-api (v0.1) + cpt-insightspec-feature-identity-service (v0.1)
    ↓
    └─→ cpt-insightspec-feature-helm-minimal (v0.1)

cpt-insightspec-feature-helm-minimal (v0.1)
    ↓
    └─→ cpt-insightspec-feature-connector-manager (v0.3)

cpt-insightspec-feature-connector-manager (v0.3)
    ↓
    └─→ cpt-insightspec-feature-transform-service (v0.4)

cpt-insightspec-feature-audit-trail (v0.5)
    ↓
    └─→ cpt-insightspec-feature-org-alerts-email (v0.6)
         ↓
         └─→ cpt-insightspec-feature-production-hardening (v0.7)
```

**Dependency Rationale**:

- `cpt-insightspec-feature-authz-plugin` requires `cpt-insightspec-feature-identity-service`: reads user_roles and person_org_membership tables
- `cpt-insightspec-feature-analytics-api` requires `cpt-insightspec-feature-authz-plugin`: every query needs access scope evaluation
- `cpt-insightspec-feature-analytics-api` requires `cpt-insightspec-feature-clickhouse-client`: query builder foundation
- `cpt-insightspec-feature-identity-resolution` requires `cpt-insightspec-feature-clickhouse-client`: reads Silver step 1, writes Silver step 2
- `cpt-insightspec-feature-identity-resolution` requires `cpt-insightspec-feature-identity-service`: shares person records
- `cpt-insightspec-feature-connector-manager` requires `cpt-insightspec-feature-helm-minimal`: needs deployment infrastructure
- `cpt-insightspec-feature-transform-service` requires `cpt-insightspec-feature-connector-manager`: dependency graph references connector metadata
- `cpt-insightspec-feature-audit-trail` requires `cpt-insightspec-feature-clickhouse-client`: stores audit events in ClickHouse
- `cpt-insightspec-feature-org-alerts-email` requires `cpt-insightspec-feature-audit-trail`: alerts and email use Redpanda (introduced by audit trail)
- `cpt-insightspec-feature-production-hardening` requires all previous features: cross-cutting hardening
- `cpt-insightspec-feature-clickhouse-client` and `cpt-insightspec-feature-identity-service` are independent of each other and can be developed in parallel
