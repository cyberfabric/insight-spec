---
status: proposed
date: 2026-04-03
---

# ADR-0003: Use insight_tenant_id Instead of tenant_id

- [ ] `p1` - **ID**: `cpt-insightspec-adr-db-insight-tenant-id`

<!-- toc -->

- [Context and Problem Statement](#context-and-problem-statement)
- [Decision Drivers](#decision-drivers)
- [Considered Options](#considered-options)
- [Decision Outcome](#decision-outcome)
  - [Consequences](#consequences)
  - [Confirmation](#confirmation)
- [Pros and Cons of the Options](#pros-and-cons-of-the-options)
  - [insight_tenant_id (prefixed)](#insighttenantid-prefixed)
  - [tenant_id (bare)](#tenantid-bare)
- [More Information](#more-information)
- [Traceability](#traceability)

<!-- /toc -->

## Context and Problem Statement

Insight ingests data from external systems (Azure, Salesforce, GitHub, Jira, etc.) that have their own `tenant_id` fields. When Bronze tables preserve source-native schemas and Silver/Gold tables unify them, the name `tenant_id` becomes ambiguous: does it refer to the Insight platform tenant or the source system's tenant? This ambiguity extends to connector configs, Redpanda events, and API payloads where both Insight and source-system fields may coexist. What naming convention should Insight use for its own tenant identifier?

## Decision Drivers

* Name collision avoidance -- Azure APIs return `tenant_id` (Azure AD tenant); Salesforce uses `org_id`; bare `tenant_id` in Insight tables is ambiguous when source fields are present in the same row or payload
* Cross-layer consistency -- the same tenant identifier appears in Bronze, Silver, Gold, MariaDB, Redpanda, Redis, and S3; one name everywhere eliminates per-layer disambiguation
* Existing connector convention -- the connector framework already uses `insight_tenant_id` and `insight_source_id` in `connection_specification` to avoid collisions with source-specific config fields (e.g., `azure_tenant_id`)
* Grep-ability -- searching for `insight_tenant_id` returns only Insight platform references; searching for `tenant_id` returns both platform and source-system results

## Considered Options

* `insight_tenant_id` (prefixed)
* `tenant_id` (bare)

## Decision Outcome

Chosen option: "`insight_tenant_id` (prefixed)", because it eliminates name collisions with source systems, aligns with the existing connector config convention, and provides unambiguous grep-ability across the entire codebase.

### Consequences

* Good, because zero ambiguity -- `insight_tenant_id` is always the Insight platform tenant, in every table, event, and API payload
* Good, because aligns with existing connector convention (`insight_tenant_id`, `insight_source_id` in connection specs)
* Good, because grep for `insight_tenant_id` returns only platform references; grep for `azure_tenant_id` returns only Azure references
* Good, because eliminates the need for per-context disambiguation rules (which `tenant_id` is this?)
* Bad, because longer column name (19 chars vs 9) -- minor ergonomic cost
* Bad, because existing DESIGN documents across the project require `tenant_id` → `insight_tenant_id` renaming -- see [Known Convention Violations](../README.md#15-known-convention-violations) for the full list
* Bad, because deviates from the common `{entity}_id` naming pattern -- but this is intentional, as `insight_tenant_id` is a platform-level qualifier, not a simple FK

### Confirmation

* All MariaDB `CREATE TABLE` statements use `insight_tenant_id`, not `tenant_id`
* All ClickHouse table definitions use `insight_tenant_id`
* All Redpanda message schemas include `insight_tenant_id`
* Code search: `grep -r "tenant_id" --include="*.rs" --include="*.sql" --include="*.yml" --include="*.yaml" --include="*.md" --include="*.toml"` should return only `insight_tenant_id` (no bare `tenant_id`)
* Connector config fields: `insight_tenant_id` in `connection_specification`, `azure_tenant_id` for Azure -- no collision

## Pros and Cons of the Options

### insight_tenant_id (prefixed)

All Insight platform tables and events use `insight_tenant_id` as the tenant isolation column. The `insight_` prefix is reserved for platform-injected fields.

* Good, because unambiguous across all layers (Bronze through Gold, MariaDB, events)
* Good, because already established in connector framework config convention
* Good, because enables mechanical validation -- any bare `tenant_id` in Insight-owned code is a bug
* Neutral, because longer name adds minor typing overhead
* Bad, because requires updating all existing spec documents

### tenant_id (bare)

Standard convention used by most multi-tenant SaaS systems. Short, familiar, widely understood.

* Good, because shortest possible name -- less typing, less visual noise
* Good, because follows the standard `{entity}_id` FK pattern
* Good, because universally recognised as "the tenant column" in multi-tenant systems
* Bad, because collides with `tenant_id` in Azure AD, Azure APIs, and potentially other source systems
* Bad, because in Bronze/Silver tables, requires disambiguation (which `tenant_id` is this row's?)
* Bad, because connector configs already had to work around this with `insight_tenant_id` prefix -- bare name was insufficient

## More Information

The connector framework established the `insight_*` prefix convention to prevent config field collisions. This ADR extends that convention from connector configs to all platform tables and events.

**Related fields using the same `insight_` prefix:**
- `insight_source_id` -- connector instance identifier
- `insight_source_type` -- source system type (e.g., `github`, `bamboohr`)

**Fields that do NOT use the prefix:**
- `source_account_id` -- this is a source-native identifier, not platform-injected

See the full field conventions in [Database Field Naming & Type Conventions](../README.md).

## Traceability

This decision directly addresses the following requirements or design elements:

* `cpt-insightspec-nfr-be-tenant-isolation` -- `insight_tenant_id` is the universal tenant isolation column across all storage systems
* `cpt-insightspec-nfr-be-query-safety` -- Unambiguous column name prevents accidental joins on wrong `tenant_id` when source-system fields are present
* `cpt-insightspec-principle-be-secure-by-default` -- Eliminates a class of bugs where platform tenant_id is confused with source-system tenant_id
