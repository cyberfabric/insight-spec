# PRD — Salesforce Connector

<!-- toc -->

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
  - [5.1 CRM Entity Extraction](#51-crm-entity-extraction)
  - [5.2 Custom Field Extraction](#52-custom-field-extraction)
  - [5.3 Connector Operations](#53-connector-operations)
  - [5.4 Data Integrity](#54-data-integrity)
  - [5.5 Identity Resolution](#55-identity-resolution)
- [6. Non-Functional Requirements](#6-non-functional-requirements)
  - [6.1 NFR Inclusions](#61-nfr-inclusions)
  - [6.2 NFR Exclusions](#62-nfr-exclusions)
- [7. Public Library Interfaces](#7-public-library-interfaces)
  - [7.1 Public API Surface](#71-public-api-surface)
  - [7.2 External Integration Contracts](#72-external-integration-contracts)
- [8. Use Cases](#8-use-cases)
  - [UC-001 Configure Salesforce Connection](#uc-001-configure-salesforce-connection)
  - [UC-002 Incremental Sync Run](#uc-002-incremental-sync-run)
- [9. Acceptance Criteria](#9-acceptance-criteria)
- [10. Dependencies](#10-dependencies)
- [11. Assumptions](#11-assumptions)
- [12. Risks](#12-risks)
- [13. Resolved Questions](#13-resolved-questions)
- [14. Non-Applicable Requirements](#14-non-applicable-requirements)

<!-- /toc -->

## 1. Overview

### 1.1 Purpose

The Salesforce Connector extracts contact records, account (company) data, opportunity (deal pipeline) records, activities (Tasks and Events), custom field values (`__c` fields), and user directory data from the Salesforce REST API via SOQL queries and loads them into the Insight platform's Bronze layer. It provides the raw material for measuring sales performance — deal pipeline velocity, win rates, activity-to-close ratios, and workload per salesperson — alongside the existing HubSpot connector in a unified CRM analytics domain.

### 1.2 Background / Problem Statement

Salesforce is the most widely deployed enterprise CRM platform. Insight already supports HubSpot as a CRM source, but many organizations — especially enterprise customers — use Salesforce as their primary sales system. To deliver unified CRM analytics across the organization, Insight must ingest Salesforce data into the same Bronze-to-Silver pipeline that already serves HubSpot.

The Salesforce REST API provides rich data via SOQL (Salesforce Object Query Language) across standard objects: Contacts, Accounts, Opportunities, Tasks, Events, and Users. The connector must handle the differences between Salesforce and HubSpot data models — most notably that Salesforce stores Tasks and Events as separate objects (unlike HubSpot's unified Engagements), uses 18-character Salesforce IDs instead of numeric IDs, and names companies "Accounts" instead of "Companies". All Salesforce API fields use PascalCase (e.g., `OwnerId`, `AccountId`) and must be normalized to snake_case at Bronze level.

Salesforce customers heavily customize their schemas with custom fields (`__c` suffix). These fields — such as `Customer_Segment__c` or `Contract_Value__c` — carry business-critical data that standard field extraction misses. The connector must collect whitelisted custom fields as key-value pairs without requiring schema changes per customer.

**Target Users**:

- Platform operators who configure Salesforce OAuth credentials, object scope, and monitor extraction runs
- Data analysts who consume Salesforce CRM data in Silver/Gold layers alongside HubSpot for unified sales performance metrics
- Sales managers and revenue operations leaders who use pipeline velocity, activity tracking, and win rate data for team performance analysis

**Key Problems Solved**:

- Lack of Salesforce data in the Insight platform, preventing unified CRM analytics across Salesforce and HubSpot teams
- No visibility into deal pipeline progression (stage transitions, time-in-stage) for Salesforce-using sales teams
- Missing activity data (calls, meetings, tasks) needed for effort-to-close analysis and salesperson workload measurement
- No cross-system identity resolution between Salesforce users and other Insight sources (Jira, GitHub, M365, Slack)
- Custom field data (`__c` fields) essential for customer segmentation and pipeline filtering not available from standard field extraction alone

### 1.3 Goals (Business Outcomes)

**Success Criteria**:

- Salesforce CRM data extracted with no missed sync windows over a 90-day period (Baseline: no Salesforce extraction; Target: v1.0)
- Per-user Salesforce activity available for identity resolution within 24 hours of extraction (Baseline: N/A; Target: v1.0)
- Salesforce data unified with HubSpot in the `class_crm_*` Silver tables for cross-source sales analytics (Baseline: HubSpot only; Target: v1.0)

**Capabilities**:

- Extract Salesforce contacts, accounts, opportunities, activities (Tasks and Events), and user directory
- Extract custom field values (`__c` fields) for Opportunities and Contacts as key-value pairs
- Incremental extraction using `LastModifiedDate` as cursor for all entity streams
- Identity resolution via `email` from Salesforce user directory, with `user_id` (18-char Salesforce ID) as internal join key
- Support for OAuth 2.0 (Connected App) and username/password + security token authentication

### 1.4 Glossary

| Term | Definition |
|------|------------|
| Salesforce REST API | Salesforce's REST API (`/services/data/v{version}/`) providing access to standard and custom objects via SOQL queries and object endpoints. |
| SOQL | Salesforce Object Query Language — SQL-like query language used to retrieve records from Salesforce objects. Supports filtering, ordering, and relationship queries. |
| Salesforce ID | 18-character case-insensitive globally unique identifier used for all Salesforce records. The `OwnerId` field on most objects references a User record. |
| Connected App | A Salesforce OAuth 2.0 application configuration that grants API access. Provides `client_id` and `client_secret` for the OAuth flow. |
| Custom Field (`__c`) | A customer-defined field on a Salesforce object, identified by the `__c` suffix (e.g., `Customer_Segment__c`). Schema metadata available via the Describe API. |
| Task | A Salesforce activity object representing a to-do item, call log, or follow-up. Uses `ActivityDate` (date only) and `Status` field. |
| Event | A Salesforce activity object representing a calendar event or meeting. Uses `StartDateTime` (datetime) and `DurationInMinutes` field. |
| Account | A Salesforce object representing a company, organization, or business entity. Equivalent to HubSpot's "Company". |
| Opportunity | A Salesforce object representing a deal or potential sale. Tracks stage, amount, probability, and close date. Equivalent to HubSpot's "Deal". |
| Record Type | A Salesforce metadata configuration that determines available picklist values and page layouts for a given object. Identified by `RecordTypeId`. Common examples: "New Business" vs "Renewal" Opportunities. |
| Field-Level Security (FLS) | A Salesforce permission setting that controls visibility of individual fields per user profile. FLS-hidden fields are silently absent from API responses. |
| Compound Field | A Salesforce field type (Address, Name, Geolocation) that returns a structured JSON object rather than a scalar value. Cannot be used in SOQL WHERE clauses. |
| OpportunityFieldHistory | A Salesforce system object that records changes to tracked fields on Opportunity. Requires Field History Tracking to be enabled in Salesforce Setup. |
| Bulk API 2.0 | Salesforce's batch data API for large-volume operations, returning data in batches up to 150MB. Consumes fewer API calls than REST+SOQL for large datasets. |
| Bronze Table | Raw data table in the destination, preserving source-native field names (normalized to snake_case) and types without transformation. |

## 2. Actors

### 2.1 Human Actors

#### Platform Operator

**ID**: `cpt-insightspec-actor-sf-operator`

**Role**: Configures Salesforce instance credentials (OAuth 2.0 Connected App or username/password + security token), selects object scope, and monitors extraction runs.
**Needs**: Ability to configure the connector with Salesforce credentials, filter by object scope, and verify that data is flowing correctly for all streams.

#### Data Analyst

**ID**: `cpt-insightspec-actor-sf-analyst`

**Role**: Consumes Salesforce contact, account, opportunity, and activity data from Silver/Gold layers to build dashboards for deal pipeline velocity, win rates, activity-to-close ratios, and salesperson workload — alongside HubSpot data in unified CRM views.
**Needs**: Complete, gap-free CRM entity data with identity resolution to canonical person IDs for cross-platform aggregation.

### 2.2 System Actors

#### Salesforce REST API

**ID**: `cpt-insightspec-actor-sf-api`

**Role**: External REST API providing SOQL-based access to Contacts, Accounts, Opportunities, Tasks, Events, Users, and custom field metadata. Enforces API call limits per 24-hour rolling window and requires OAuth 2.0 or session-based authentication.

#### Identity Manager

**Ref**: `cpt-insightspec-actor-identity-manager`

**Role**: Resolves `email` from Salesforce Bronze user table to canonical `person_id` in Silver step 2. Enables cross-system joins (Salesforce + HubSpot + Jira + GitHub + M365 + Slack, etc.).

## 3. Operational Concept & Environment

### 3.1 Module-Specific Environment Constraints

- Requires a Salesforce account with API access enabled and sufficient permissions to query Contacts, Accounts, Opportunities, Tasks, Events, and Users via SOQL
- Authentication via OAuth 2.0 (Connected App with `client_id`, `client_secret`, `refresh_token`) or legacy username/password + security token
- The connector operates as a batch collector using incremental sync based on `LastModifiedDate`
- The connector **SHOULD** run at least daily to maintain timely opportunity stage and activity data
- Salesforce enforces API call limits per 24-hour rolling window (varies by edition: 15,000 for Enterprise, 5,000 for Professional); the connector must track API call consumption and handle limit errors gracefully
- PascalCase API field names (e.g., `OwnerId`, `AccountId`) are normalized to snake_case at Bronze level

## 4. Scope

### 4.1 In Scope

- Extraction of Salesforce contacts with core fields and account association
- Extraction of accounts (companies) with hierarchy support (`parent_account_id`)
- Extraction of opportunities (deals) with stage, amount, probability, and close date
- Extraction of activities as separate Bronze streams: `salesforce_tasks` and `salesforce_events` (merged into `class_crm_activities` at Silver)
- Extraction of custom field values (`__c` fields) for Opportunities and Contacts as key-value pairs
- Extraction of Opportunity stage history (`OpportunityFieldHistory` for `StageName` and `Amount` fields)
- Extraction of Salesforce user directory for identity resolution with SCD Type 2 history
- Soft-delete detection via `salesforce_deleted_records` stream (`queryAll` with `IsDeleted = true`)
- Connector execution monitoring via collection runs stream
- Incremental sync using `LastModifiedDate` as cursor for all entity streams
- Identity resolution via `email` from user directory
- OAuth 2.0 (Connected App) and username/password + security token authentication
- All timestamps normalized to UTC
- `insight_source_id`, `tenant_id`, and `data_source = 'insight_salesforce'` stamped on every record
- Sandbox vs. production org detection during connection configuration

### 4.2 Out of Scope

- Silver/Gold layer transformations — responsibility of the CRM domain pipeline
- Silver step 2 (identity resolution: `email` → `person_id`) — responsibility of the Identity Manager
- Real-time streaming — this connector operates in batch mode
- Salesforce Service Cloud data (Cases, SLAs, customer satisfaction)
- Salesforce Marketing Cloud or Pardot data
- Einstein Analytics or AI prediction data
- Custom object auto-discovery beyond Opportunity and Contact `__c` fields
- Salesforce webhooks or Streaming API (push-based collection)
- Account hierarchy traversal or recursive parent resolution — flat `parent_account_id` is stored; tree-building is a Silver concern
- FieldHistory tracking beyond `StageName` and `Amount` on Opportunity — additional field histories deferred to a future release
- Salesforce Bulk API 2.0 — deferred to DESIGN as an optimization path for large orgs (see Risks)
- Attachment or file downloads from Salesforce

## 5. Functional Requirements

### 5.1 CRM Entity Extraction

#### Extract Contacts

- [ ] `p1` - **ID**: `cpt-insightspec-fr-sf-contact-extraction`

The connector **MUST** extract Salesforce Contact records with core fields including: contact ID, email, first name, last name, title, associated account ID, record owner ID, record type ID, lead source, creation timestamp, and last modified timestamp.

**Rationale**: Contacts are the primary external-facing CRM entity. Account association and owner linkage enable per-salesperson contact portfolio analysis and account coverage metrics.

**Actors**: `cpt-insightspec-actor-sf-api`, `cpt-insightspec-actor-sf-analyst`

#### Extract Accounts

- [ ] `p1` - **ID**: `cpt-insightspec-fr-sf-account-extraction`

The connector **MUST** extract Salesforce Account records with core fields including: account ID, name, website, industry, type (Customer/Partner/Prospect), owner ID, record type ID, parent account ID (for hierarchies), creation timestamp, and last modified timestamp.

**Rationale**: Accounts represent companies in the sales pipeline. Account hierarchy data enables roll-up analytics (subsidiary → parent company). Industry and type fields enable segmentation analysis.

**Actors**: `cpt-insightspec-actor-sf-api`, `cpt-insightspec-actor-sf-analyst`

#### Extract Opportunities

- [ ] `p1` - **ID**: `cpt-insightspec-fr-sf-opportunity-extraction`

The connector **MUST** extract Salesforce Opportunity records with core fields including: opportunity ID, name, stage name, amount, currency ISO code (for multi-currency orgs), close date, probability, owner ID, account ID, record type ID, lead source, is_closed flag, is_won flag, creation timestamp, and last modified timestamp.

**Rationale**: Opportunities are the core entity for deal pipeline analytics — stage progression, time-in-stage, win/loss rates, and pipeline value forecasting all depend on complete opportunity data. `currency_iso_code` is required for multi-currency orgs where amounts are stored in different currencies per record — without it, pipeline value aggregation produces incorrect totals. `record_type_id` enables segmentation by opportunity type (e.g., "New Business" vs. "Renewal").

**Actors**: `cpt-insightspec-actor-sf-api`, `cpt-insightspec-actor-sf-analyst`

#### Extract Tasks

- [ ] `p1` - **ID**: `cpt-insightspec-fr-sf-task-extraction`

The connector **MUST** extract Salesforce Task records into a dedicated `salesforce_tasks` Bronze stream via `SELECT ... FROM Task`. Core fields include: task ID, subject, owner ID, who ID (contact/lead reference), who type (`Contact` or `Lead`), what ID (related object reference), what type (`Account` / `Opportunity` / `Campaign` / `Case` / etc.), activity date, status, call type (call-logged tasks only), call duration seconds (call-logged tasks only), creation timestamp, and last modified timestamp.

**Rationale**: Tasks represent to-do items, call logs, and follow-ups — a core salesperson activity signal. Keeping Tasks as a separate Bronze stream preserves the source-native 1:1 mapping (one Salesforce object = one Bronze table), avoids nullable fields from Event-specific columns, and enables a simple single-cursor incremental sync per stream. The Silver layer merges Tasks and Events into `class_crm_activities` via dbt.

**Actors**: `cpt-insightspec-actor-sf-api`, `cpt-insightspec-actor-sf-analyst`

#### Extract Events

- [ ] `p1` - **ID**: `cpt-insightspec-fr-sf-event-extraction`

The connector **MUST** extract Salesforce Event records into a dedicated `salesforce_events` Bronze stream via `SELECT ... FROM Event`. Core fields include: event ID, subject, owner ID, who ID (contact/lead reference), who type (`Contact` or `Lead`), what ID (related object reference), what type (`Account` / `Opportunity` / `Campaign` / `Case` / etc.), start datetime, end datetime, duration in minutes, creation timestamp, and last modified timestamp.

**Rationale**: Events represent calendar meetings and scheduled activities. Keeping Events as a separate Bronze stream follows the same architecture principles as Tasks: source-native schema, single cursor, no nullable cross-type fields. The Silver layer merges with Tasks into `class_crm_activities`.

**Actors**: `cpt-insightspec-actor-sf-api`, `cpt-insightspec-actor-sf-analyst`

#### Resolve Polymorphic References on Activities

- [ ] `p1` - **ID**: `cpt-insightspec-fr-sf-polymorphic-resolution`

Both `salesforce_tasks` and `salesforce_events` streams **MUST** include `who_type` and `what_type` discriminator fields populated by resolving the Salesforce polymorphic `WhoId` and `WhatId` references. The connector **MUST** derive the object type from the Salesforce ID prefix (first 3 characters encode the object type via the `KeyPrefix` in the Describe API) or by using SOQL `TYPEOF` / `Name.Type` relationship queries. The connector **MUST NOT** leave `who_type` or `what_type` as null when the corresponding ID field is non-null.

**Rationale**: `WhoId` can reference a Contact or Lead; `WhatId` can reference an Account, Opportunity, Campaign, Case, or custom object. Without type discriminators, downstream analytics require trial-and-error JOINs across all possible target tables.

**Actors**: `cpt-insightspec-actor-sf-api`, `cpt-insightspec-actor-sf-analyst`

#### Extract Opportunity Stage History

- [ ] `p2` - **ID**: `cpt-insightspec-fr-sf-opportunity-history`

The connector **MUST** extract the `OpportunityFieldHistory` object for the `StageName` and `Amount` fields, including: opportunity ID, field name, old value, new value, change timestamp (`CreatedDate`), and the user who made the change (`CreatedById`).

**Rationale**: The PRD's stated goals include "deal pipeline velocity" and "time-in-stage" analytics. The current `salesforce_opportunities` table captures only the current snapshot — it cannot answer "how long was this deal in Negotiation?" or "when did it move from Qualification to Proposal?". `OpportunityFieldHistory` is the Salesforce equivalent of Jira's changelog, which the Jira connector treats as P1. Without stage history, only current-snapshot pipeline analytics are possible, not the time-series pipeline velocity metrics that distinguish Insight from basic CRM reporting. Stage history for `StageName` and `Amount` is a minimal viable set; additional fields (e.g., `CloseDate`, `Probability`) can be added in a future release.

**Actors**: `cpt-insightspec-actor-sf-api`, `cpt-insightspec-actor-sf-analyst`

#### Extract User Directory

- [ ] `p1` - **ID**: `cpt-insightspec-fr-sf-user-extraction`

The connector **MUST** extract the Salesforce user directory, including: user ID (18-char Salesforce ID), email, first name, last name, title, department, profile name (requires `Profile.Name` relationship query), and active status.

**Rationale**: The user directory provides the email identity key for cross-system resolution and the salesperson roster needed to associate all owned CRM objects with their operators.

**Actors**: `cpt-insightspec-actor-sf-api`, `cpt-insightspec-actor-identity-manager`

#### Preserve User Directory History (SCD Type 2)

- [ ] `p1` - **ID**: `cpt-insightspec-fr-sf-user-scd`

The `salesforce_users` table **MUST** preserve historical state changes using the SCD Type 2 pattern. Each user record **MUST** include `valid_from` (timestamp when this state became effective) and `valid_to` (timestamp when this state was superseded, or `null` for the current record). When the connector detects a change in a user's attributes (email, title, department, profile, active status) between the current full refresh response and the most recent stored record, it **MUST** close the previous record (set `valid_to = collected_at`) and insert a new record with `valid_from = collected_at`.

The Airbyte sync mode for `salesforce_users` **MUST** be **Full Refresh | Append** (not overwrite), so that each run appends the current snapshot. SCD Type 2 versioning **MUST** be applied so that superseded records are closed and new records are opened. The implementation approach (destination-level MERGE logic vs. connector-level change detection) is deferred to DESIGN.

**Rationale**: The Salesforce User API returns current state only. Without SCD Type 2, an email change (e.g., name change after marriage), title change (promotion), or deactivation (departure) silently overwrites history. Historical analytics ("which email was this salesperson using when they closed that deal?", "when was this user deactivated?") require point-in-time user state. Additionally, email reuse on deactivated accounts (departed employee's email reassigned to new hire) creates identity resolution collisions — SCD Type 2 with temporal bounds allows the Identity Manager to disambiguate.

**Actors**: `cpt-insightspec-actor-sf-analyst`, `cpt-insightspec-actor-identity-manager`

#### Validate Field-Level Security Coverage

- [ ] `p1` - **ID**: `cpt-insightspec-fr-sf-fls-validation`

During connection configuration (UC-001), the connector **MUST** call the Describe API for each target object and compare the fields returned against the Bronze schema's expected field set. If any schema-defined field is not visible to the authenticated user (due to Salesforce Field-Level Security restrictions), the connector **MUST** log a warning listing all hidden fields and their parent object. The connector **MUST NOT** fail extraction due to FLS-hidden fields — it **MUST** emit `null` for hidden fields and continue.

At the start of each sync run, the connector **SHOULD** re-validate FLS coverage and include a summary of hidden fields in the collection run log.

**Rationale**: Salesforce Field-Level Security (FLS) can make specific fields invisible to the API user without returning an error. A SOQL query succeeds but the restricted field is simply absent from the response. Without proactive FLS validation, the connector silently produces incomplete records (e.g., `Amount` missing from Opportunities, `Email` missing from Contacts) with no indication to the operator. This is particularly dangerous for identity resolution — if `email` is FLS-restricted on the User object, the entire identity chain breaks silently.

**Actors**: `cpt-insightspec-actor-sf-api`, `cpt-insightspec-actor-sf-operator`

### 5.2 Custom Field Extraction

#### Extract Opportunity Custom Fields

- [ ] `p2` - **ID**: `cpt-insightspec-fr-sf-opportunity-custom-fields`

The connector **MUST** extract custom field values (`__c` suffix) for Opportunity records as key-value pairs, including: parent opportunity ID, field API name, field label, field value (as string), value type hint, and collection timestamp. Custom field metadata **MUST** be discovered via the Describe API (`GET /services/data/v{version}/sobjects/Opportunity/describe`). Only fields with non-null values are written as rows.

**Architectural constraint**: The Airbyte Declarative Connector framework (YAML) does not natively support dynamic unnest — taking a variable-length dictionary of `__c` fields from a JSON response and expanding it into separate key-value rows. This transformation requires a custom Python component (Custom Record Extractor or Python CDK migration). The DESIGN **MUST** specify whether custom field extraction is implemented as: (1) a custom `RecordExtractor` within the Declarative manifest, (2) a hybrid manifest with Python components, or (3) a full Python CDK connector. Pure Declarative YAML is insufficient for this requirement.

**Compound field handling**: Salesforce supports compound field types (Address, Name, Geolocation) that return structured JSON objects instead of scalar values. Custom compound fields (`__c` of type Address or Geolocation) **MUST** be serialized as JSON strings with `value_type = 'json'`. The SOQL character limit (100,000 characters) **MUST** be respected — if the SELECT clause for all `__c` fields approaches this limit, the connector **MUST** split the query into multiple SOQL requests with subsets of custom fields.

**Rationale**: Organization-specific opportunity fields (customer segment, product line, region) are essential for pipeline filtering and segmentation analytics. A key-value model avoids schema changes when customers add new custom fields.

**Actors**: `cpt-insightspec-actor-sf-api`, `cpt-insightspec-actor-sf-analyst`

#### Extract Contact Custom Fields

- [ ] `p2` - **ID**: `cpt-insightspec-fr-sf-contact-custom-fields`

The connector **MUST** extract custom field values (`__c` suffix) for Contact records as key-value pairs, including: parent contact ID, field API name, field label, field value (as string), value type hint, and collection timestamp. Custom field metadata **MUST** be discovered via the Describe API (`GET /services/data/v{version}/sobjects/Contact/describe`). Only fields with non-null values are written as rows.

**Architectural constraint**: Same as `cpt-insightspec-fr-sf-opportunity-custom-fields` — dynamic unnest of `__c` fields requires a custom Python component beyond pure Declarative YAML.

**Rationale**: Customer-specific contact fields (tier, preferred language, contract reference) enable richer contact segmentation and portfolio analysis.

**Actors**: `cpt-insightspec-actor-sf-api`, `cpt-insightspec-actor-sf-analyst`

### 5.3 Connector Operations

#### Track Collection Runs

- [ ] `p2` - **ID**: `cpt-insightspec-fr-sf-collection-runs`

The connector **MUST** produce a collection run log entry for each execution, recording: run ID, start/end time, status, per-stream record counts (contacts, accounts, opportunities, opportunity history, activities, users), API call count, API budget remaining (parsed from the final `Sforce-Limit-Info: api-usage=N/M` response header), error count, FLS-hidden field count, and collection settings (instance URL, org type, object types, lookback configuration).

**Rationale**: Operational visibility into connector health. Enables alerting on failed runs, tracking data completeness, and monitoring API call consumption against Salesforce edition limits. The `Sforce-Limit-Info` value is returned on every successful API response and provides the only way to trend API budget consumption without waiting for a 403 failure.

**Actors**: `cpt-insightspec-actor-sf-operator`

### 5.4 Data Integrity

#### Deduplicate by Primary Key

- [ ] `p1` - **ID**: `cpt-insightspec-fr-sf-deduplication`

Each stream **MUST** define a primary key that ensures re-running the connector for an overlapping date range does not produce duplicate records.

The connector **MUST** generate a surrogate URN-based primary key for entity records in the format `urn:salesforce:{tenant_id}:{insight_source_id}:{record_id}`. The original `insight_source_id`, `tenant_id`, and Salesforce 18-char ID fields **MUST** be preserved as separate columns for filtering and joins. The URN key eliminates the need for composite key joins in downstream analytics.

Custom field ext streams use `(insight_source_id, entity_id, field_api_name)` as the composite key.

The Airbyte sync mode for all entity streams (contacts, accounts, opportunities, activities, opportunity history) **MUST** be **Incremental | Append + Deduped** (upsert/merge semantics). The `salesforce_users` stream **MUST** use **Full Refresh | Append** with SCD Type 2 handling (see `cpt-insightspec-fr-sf-user-scd`). The `salesforce_deleted_records` stream **MUST** use **Incremental | Append**.

**Rationale**: Without explicit upsert semantics, overlapping incremental windows produce duplicate rows. URN-based surrogate keys provide unambiguous cross-org identity while keeping component fields available for filtering, matching the pattern established by the Jira connector (`urn:jira:{tenant_id}:{insight_source_id}:{issue_key}`).

**Actors**: `cpt-insightspec-actor-sf-api`

#### Support Incremental Collection

- [ ] `p1` - **ID**: `cpt-insightspec-fr-sf-incremental-sync`

The connector **MUST** support incremental collection using the `LastModifiedDate` field as cursor for all entity streams, so that ongoing runs process only newly created or modified records without requiring full reloads. SOQL queries **MUST** filter by `LastModifiedDate > {cursor}` with `ORDER BY LastModifiedDate ASC`.

**Known limitation**: Incremental sync by `LastModifiedDate` is blind to hard-deleted records (permanently purged from Recycle Bin). Soft-deleted records (in the Recycle Bin) are captured by the `salesforce_deleted_records` stream (see `cpt-insightspec-fr-sf-deleted-records`). Permanently purged records are invisible to all API endpoints. The connector **SHOULD** support a periodic full reconciliation run to detect permanently purged records that no longer exist in the source.

**Rationale**: Full reloads are impractical for large Salesforce instances with millions of records across objects. Incremental sync is required for sustainable daily operation.

**Actors**: `cpt-insightspec-actor-sf-operator`

#### Detect Deleted Records

- [ ] `p1` - **ID**: `cpt-insightspec-fr-sf-deleted-records`

The connector **MUST** provide a `salesforce_deleted_records` stream that uses the Salesforce `queryAll` endpoint with `WHERE IsDeleted = true AND SystemModstamp > {cursor}` to capture soft-deleted records (those in the Salesforce Recycle Bin). Each record **MUST** include: object type (`Contact` / `Account` / `Opportunity` / `Task` / `Event`), record ID, deletion timestamp (`SystemModstamp`), `insight_source_id`, and `tenant_id`.

The downstream Silver pipeline uses this stream to mark corresponding Bronze records as deleted (soft-delete flag or tombstone) rather than leaving stale "active" records in analytics.

**Rationale**: For CRM analytics, stale opportunities inflating the pipeline is a data quality problem. If a salesperson deletes a lost Opportunity, the Bronze layer must reflect that deletion within the same day's sync. Salesforce retains soft-deleted records in the Recycle Bin for 15 days (default) before permanent purge, so `queryAll` with `IsDeleted = true` captures the vast majority of deletions in day-to-day operation. This is materially better than relying solely on periodic full reconciliation, which would leave the pipeline inflated for up to a week.

**Actors**: `cpt-insightspec-actor-sf-api`, `cpt-insightspec-actor-sf-analyst`

#### Handle API Call Limits

- [ ] `p1` - **ID**: `cpt-insightspec-fr-sf-api-limits`

The connector **MUST** handle Salesforce API limit errors (HTTP 403 with `REQUEST_LIMIT_EXCEEDED`) via the Airbyte framework's standard error handling: exponential backoff retries followed by sync failure if the limit persists.

**Architectural constraint**: The Airbyte Declarative framework does not support proactive API quota inspection (reading `Sforce-Limit-Info` response headers to anticipate exhaustion and stop gracefully). When `REQUEST_LIMIT_EXCEEDED` is returned, the framework retries with backoff and eventually fails the sync. The cursor state is preserved only for pages already committed to the destination via Airbyte's state checkpointing mechanism — records fetched but not yet flushed are lost and will be re-fetched on the next run. The connector **MUST NOT** assume mid-page graceful shutdown capability.

To mitigate shared API budget exhaustion:
1. The connector **SHOULD** be scheduled during off-peak hours to minimize contention with other org integrations.
2. The collection run log **MUST** record API call count per run to enable operators to monitor consumption trends.
3. If proactive budget management is required (e.g., stopping after N API calls), the DESIGN **MUST** specify a Python CDK migration path that reads `Sforce-Limit-Info` headers and implements soft shutdown before the limit is hit.

**Rationale**: Salesforce API call limits are shared across all integrations in the org. Exhausting the daily budget blocks other business-critical integrations (e.g., marketing automation, customer support tools). The connector must be a responsible consumer of the shared API budget, but the PRD must reflect realistic Airbyte framework capabilities rather than assuming proactive budget control.

**Actors**: `cpt-insightspec-actor-sf-api`, `cpt-insightspec-actor-sf-operator`

#### Preserve Source-Native Field Names

- [ ] `p1` - **ID**: `cpt-insightspec-fr-sf-field-preservation`

All Salesforce API fields **MUST** be preserved in their source-native PascalCase form at Bronze level (e.g., `OwnerId`, `AccountId`, `LastModifiedDate`). Field name normalization to snake_case is a Silver-layer responsibility, handled by dbt transformations alongside cross-source schema unification.

**Rationale**: The platform's architecture principle is that Bronze preserves source-native schema (Connector Framework DESIGN §1.3, Connector Framework PRD §1.4 Glossary, Ingestion Layer DESIGN §1.3). Normalizing at Bronze would mean the Bronze layer no longer matches the Salesforce API response, complicating debugging and violating the "raw archive" contract. All other connectors (HubSpot, Jira, GitHub) preserve source-native field names at Bronze.

**Actors**: `cpt-insightspec-actor-sf-api`

### 5.5 Identity Resolution

#### Expose Identity Key

- [ ] `p1` - **ID**: `cpt-insightspec-fr-sf-identity-key`

All user-attributed streams **MUST** include `owner_id` (18-char Salesforce User ID) that joins to `salesforce_users.user_id`. The user directory **MUST** include `email` as the identity resolution key.

The Identity Manager (Silver step 2) resolves identity as follows:
1. `salesforce_users.email` → canonical `person_id` via the standard email resolution path
2. `salesforce_contacts.email` is for external customers — not resolved to `person_id` (same boundary as HubSpot contacts)

**Rationale**: Cross-system identity resolution is the foundation of the Insight platform's analytics. Email is the canonical cross-system key. The internal/external boundary (users = salespeople = resolved; contacts = customers = not resolved) matches the HubSpot connector's identity model.

**Actors**: `cpt-insightspec-actor-identity-manager`

#### Stamp Instance and Tenant Context

- [ ] `p1` - **ID**: `cpt-insightspec-fr-sf-instance-context`

Every record emitted by the connector **MUST** include `insight_source_id` (identifying the specific Salesforce org), `tenant_id` (identifying the Insight tenant), and `data_source` (set to `insight_salesforce` for all records). These fields are required for multi-instance disambiguation, tenant isolation, and source identification when Salesforce data merges with HubSpot data in unified `class_crm_*` Silver tables.

**Rationale**: Multiple Salesforce orgs (production, sandbox, acquired companies) may feed into the same Bronze store. Without `insight_source_id`, Salesforce 18-char IDs could collide across orgs. The `data_source` field enables the Silver pipeline to distinguish Salesforce-originated records from HubSpot-originated records in the unified CRM schema, matching the pattern established by the Slack connector (`data_source = 'insight_slack'`).

**Actors**: `cpt-insightspec-actor-sf-operator`

#### Normalize Timestamps to UTC

- [ ] `p1` - **ID**: `cpt-insightspec-fr-sf-utc-timestamps`

All timestamps persisted in the Bronze layer **MUST** be stored in UTC. Salesforce API returns timestamps in ISO 8601 format with timezone offsets (typically UTC already, but the connector **MUST** normalize any non-UTC offsets). Activity dates **MUST** preserve the date-only (`Date`) vs datetime (`DateTime64(3)`) distinction from the source (Tasks use `ActivityDate` as date; Events use `StartDateTime` as datetime).

**Rationale**: Consistent UTC normalization prevents timezone-related errors in cross-platform analytics, especially for globally distributed sales teams.

**Actors**: `cpt-insightspec-actor-sf-analyst`

## 6. Non-Functional Requirements

### 6.1 NFR Inclusions

#### Data Freshness

- [ ] `p1` - **ID**: `cpt-insightspec-nfr-sf-freshness`

The connector **MUST** deliver extracted data to the Bronze layer within 24 hours of the connector's scheduled run.

**Threshold**: Data available in Bronze ≤ 24h after scheduled collection time.

**Rationale**: Timely opportunity and activity data enables near-real-time pipeline dashboards. Stale data reduces the value of sales performance analysis and forecasting.

#### Extraction Completeness

- [ ] `p1` - **ID**: `cpt-insightspec-nfr-sf-completeness`

The connector **MUST** extract all records matching the configured object scope and date range on each successful run. Failed or partial runs must be detectable and retryable without data loss.

**Rationale**: Incomplete extraction leads to understated pipeline values, incorrect win rates, and unreliable activity-to-close metrics.

#### Timestamp Normalization

- [ ] `p1` - **ID**: `cpt-insightspec-nfr-sf-utc-timestamps`

All timestamps persisted in the Bronze layer **MUST** be stored in UTC (ISO 8601 format).

**Threshold**: Zero non-UTC timestamps in Bronze tables.

**Rationale**: Salesforce returns timestamps with timezone information. For globally distributed sales teams, inconsistent timestamp storage would corrupt time-based analytics at the Silver/Gold layer.

### 6.2 NFR Exclusions

- **Real-time streaming latency**: Not applicable — this connector operates in batch mode with daily incremental sync.
- **Throughput / high-volume optimization**: Not applicable for most streams. Large Salesforce orgs may require SOQL pagination tuning but the API handles this natively via `queryMore`.
- **Availability**: Batch connector — availability is determined by the orchestrator's scheduling, not by this connector.

## 7. Public Library Interfaces

### 7.1 Public API Surface

#### Salesforce Stream Contract

- [ ] `p1` - **ID**: `cpt-insightspec-interface-sf-streams`

**Type**: Data format (Bronze table schemas)

**Stability**: stable

**Description**: Twelve Bronze streams — `salesforce_contacts`, `salesforce_accounts`, `salesforce_opportunities`, `salesforce_opportunity_history`, `salesforce_tasks`, `salesforce_events`, `salesforce_users`, `salesforce_opportunity_ext`, `salesforce_contact_ext`, `salesforce_deleted_records`, `salesforce_collection_runs`. Tasks and Events are separate streams (one Salesforce object = one Bronze table), merged at Silver into `class_crm_activities`. All user-attributed streams reference `OwnerId` (source-native PascalCase) as the user key. Entity streams use `LastModifiedDate` as the cursor field, with URN-based surrogate primary keys. Field names are preserved in source-native PascalCase at Bronze; snake_case normalization happens at Silver. All records include `data_source = 'insight_salesforce'`.

**Field-level schemas**: Defined in [`salesforce.md`](../salesforce.md) (Bronze table definitions with column types, descriptions, and API field mappings).

**Breaking Change Policy**: Adding new fields is non-breaking. Removing or renaming fields requires a migration.

### 7.2 External Integration Contracts

#### Salesforce REST API

- [ ] `p1` - **ID**: `cpt-insightspec-contract-sf-rest-api`

**Direction**: required from external system

**Protocol/Format**: REST / JSON (SOQL queries)

| Stream | Endpoint / SOQL | Method |
|--------|----------------|--------|
| `salesforce_contacts` | `SELECT ... FROM Contact WHERE LastModifiedDate > {cursor}` | SOQL — incremental |
| `salesforce_accounts` | `SELECT ... FROM Account WHERE LastModifiedDate > {cursor}` | SOQL — incremental |
| `salesforce_opportunities` | `SELECT ... FROM Opportunity WHERE LastModifiedDate > {cursor}` | SOQL — incremental |
| `salesforce_tasks` | `SELECT ... FROM Task WHERE LastModifiedDate > {cursor}` | SOQL — incremental |
| `salesforce_events` | `SELECT ... FROM Event WHERE LastModifiedDate > {cursor}` | SOQL — incremental |
| `salesforce_opportunity_history` | `SELECT ... FROM OpportunityFieldHistory WHERE Field IN ('StageName','Amount')` | SOQL — incremental |
| `salesforce_users` | `SELECT ..., Profile.Name FROM User` | SOQL — full refresh (SCD Type 2) |
| `salesforce_opportunity_ext` | Custom fields from Opportunity SOQL response | Extracted from entity payload |
| `salesforce_contact_ext` | Custom fields from Contact SOQL response | Extracted from entity payload |
| `salesforce_deleted_records` | `queryAll` with `WHERE IsDeleted = true AND SystemModstamp > {cursor}` per object type | SOQL (`queryAll`) — incremental |
| Custom field metadata | `GET /services/data/v{version}/sobjects/{Object}/describe` | REST — configuration |

**Authentication**: OAuth 2.0 (Connected App — `client_id`, `client_secret`, `refresh_token`) or username/password + security token

**Compatibility**: Salesforce REST API v59.0+. Response format is JSON with cursor-based pagination (`nextRecordsUrl` from `queryMore`). Field additions are non-breaking.

## 8. Use Cases

### UC-001 Configure Salesforce Connection

- [ ] `p1` - **ID**: `cpt-insightspec-usecase-sf-configure`

**Actor**: `cpt-insightspec-actor-sf-operator`

**Preconditions**:

- Salesforce org with API access enabled
- Connected App created (for OAuth) or user credentials with API permission available

**Main Flow**:

1. Operator selects authentication method (OAuth 2.0 or username/password)
2. For OAuth: operator provides `client_id`, `client_secret`, and completes the OAuth flow to obtain `refresh_token`
3. For username/password: operator provides username, password, and security token
4. System validates credentials against the Salesforce API (`/services/data/`)
5. System discovers the Salesforce org instance URL, API version, and org type (production vs. sandbox) from the OAuth token response or instance URL pattern
6. If sandbox detected: system displays a warning that sandbox data may duplicate production records and labels the connection as `sandbox` in `insight_source_id` metadata
7. System queries the Describe API for each target object and validates Field-Level Security (FLS) coverage — reports any schema-defined fields that are not visible to the authenticated user
8. System presents available objects and custom field metadata
9. Operator confirms object scope (default: all standard objects + all `__c` fields on Opportunity and Contact)
10. System pins the API version (default: latest stable, operator can override) and initializes the connection with empty state

**Postconditions**:

- Connection is ready for first sync run
- Authentication credentials are securely stored
- Org type (production/sandbox) recorded in connection metadata
- FLS coverage report available for operator review

**Alternative Flows**:

- **Invalid credentials**: System reports authentication failure; operator corrects credentials
- **Insufficient API permissions**: System reports which objects are inaccessible; operator adjusts user profile permissions
- **FLS-hidden fields**: System reports which schema-defined fields are not visible due to FLS; operator adjusts field-level permissions or acknowledges gaps
- **API not enabled**: System detects API access is disabled for the org/user; operator enables API access in Salesforce Setup
- **Connected App not authorized**: OAuth flow returns `invalid_grant`; operator re-authorizes the Connected App
- **Sandbox org detected**: System warns about sandbox data duplication risk; operator confirms or cancels

### UC-002 Incremental Sync Run

- [ ] `p1` - **ID**: `cpt-insightspec-usecase-sf-incremental-sync`

**Actor**: `cpt-insightspec-actor-sf-operator`

**Preconditions**:

- Connection configured and credentials valid
- Previous state available (or empty for first run)

**Main Flow**:

1. Orchestrator triggers the connector with current state
2. Connector queries each entity stream via SOQL with `LastModifiedDate > {cursor}` filter
3. For Contacts and Opportunities: extract core fields and collect `__c` custom field values into ext tables
4. For Tasks and Events: query each as a separate Bronze stream (`salesforce_tasks`, `salesforce_events`) with independent cursors
5. Connector refreshes user directory (full refresh with `Profile.Name` relationship query)
6. Updated cursor position captured after successful write
7. Collection run log entry written with per-stream record counts and API call consumption

**Postconditions**:

- Bronze tables contain new and updated records
- State updated with latest `LastModifiedDate` per stream
- Collection run log records success/failure and per-stream counts

**Alternative Flows**:

- **First run**: Connector extracts all records matching the object scope (full initial load)
- **API limit exhausted (HTTP 403)**: Airbyte retries with backoff; if limit persists, sync fails. State checkpointing preserves cursor for committed pages; uncommitted pages are re-fetched on next run
- **Pagination**: Large result sets use `queryMore` endpoint for continuation; no truncated results
- **Profile.Name unavailable**: If user lacks permission to query Profile, connector logs a warning and emits `null` for the profile field

## 9. Acceptance Criteria

- [ ] Contacts, accounts, and opportunities extracted from a live Salesforce org with core fields including `record_type_id` and `currency_iso_code` (opportunities)
- [ ] Opportunity stage history (`StageName`, `Amount`) extracted from `OpportunityFieldHistory`
- [ ] Tasks and Events extracted as separate Bronze streams (`salesforce_tasks`, `salesforce_events`) with independent cursors; `who_type` and `what_type` polymorphic discriminators populated on both
- [ ] User directory extracted with email, title, department, profile, and active status; SCD Type 2 preserves historical state
- [ ] Custom field values (`__c`) extracted for Opportunities and Contacts as key-value pairs; compound fields serialized as JSON
- [ ] Incremental sync on second run extracts only newly modified records (no full reload)
- [ ] `owner_id` joins to `salesforce_users.user_id` in all user-attributed records
- [ ] URN-based surrogate primary keys (`urn:salesforce:{tenant_id}:{insight_source_id}:{record_id}`) on all entity streams
- [ ] `insight_source_id`, `tenant_id`, and `data_source = 'insight_salesforce'` present in all records
- [ ] All timestamps stored in UTC
- [ ] Source-native PascalCase field names preserved in all Bronze tables (snake_case normalization at Silver)
- [ ] FLS coverage validated at connection configuration; hidden fields logged as warnings
- [ ] Sandbox vs. production org detected and labeled during connection setup
- [ ] Collection run log records success, per-stream record counts, API call count, and API budget remaining (`Sforce-Limit-Info`)
- [ ] Soft-deleted records detected via `salesforce_deleted_records` stream using `queryAll` with `IsDeleted = true`
- [ ] API call limit exhaustion (HTTP 403) handled by Airbyte retry/backoff; state checkpointing preserves cursor for committed pages

## 10. Dependencies

| Dependency | Description | Criticality |
|------------|-------------|-------------|
| Salesforce REST API | SOQL queries for Contacts, Accounts, Opportunities, Tasks, Events, Users, and Describe endpoints for custom field metadata | `p1` |
| Salesforce credentials | OAuth 2.0 Connected App tokens or username/password + security token | `p1` |
| Airbyte Connector framework | Execution model for running the connector. Declarative YAML for standard streams; Python CDK or custom `RecordExtractor` components required for custom field unnest and (optionally) proactive API budget management | `p1` |
| Identity Manager | Resolves `email` to `person_id` in Silver step 2 | `p2` |
| Destination store (PostgreSQL / ClickHouse) | Target for Bronze tables | `p1` |

## 11. Assumptions

- The Salesforce org has API access enabled and the authenticated user has read permissions across Contacts, Accounts, Opportunities, Tasks, Events, and Users
- OAuth 2.0 Connected App is the preferred authentication method; username/password + security token is supported as a fallback for orgs without Connected App configuration
- `LastModifiedDate` is available and reliable as an incremental sync cursor on all standard objects
- Salesforce returns timestamps in ISO 8601 format, typically in UTC; any timezone offsets are normalized at Bronze level
- Tasks and Events are separate Salesforce objects extracted as separate Bronze streams (`salesforce_tasks`, `salesforce_events`) with independent `LastModifiedDate` cursors; merged into `class_crm_activities` at Silver via dbt
- Bronze tables preserve source-native PascalCase field names (e.g., `OwnerId`, `AccountId`, `LastModifiedDate`); snake_case normalization is a Silver-layer responsibility, consistent with the platform's "Bronze = source-native schema" principle
- Custom fields (`__c` suffix) on Opportunity and Contact objects are discoverable via the Describe API; field metadata (API name, label, type) is stable across sync runs
- The `Profile.Name` field requires a relationship query (`SELECT Profile.Name FROM User`) and may not be available if the authenticated user lacks the "View Setup and Configuration" permission
- Salesforce API call limits are shared across all integrations in the org; the connector must monitor and respect the daily budget
- Soft-deleted records (in the Recycle Bin) are excluded from standard SOQL queries but may be retrieved via `queryAll`; permanently purged records are invisible to the connector
- `salesforce_contacts.email` represents external customer email and is not resolved to `person_id`; only `salesforce_users.email` (internal salespeople) participates in identity resolution
- Account hierarchy data (`parent_account_id`) is stored as a flat reference; recursive parent traversal is a Silver/Gold concern
- The Airbyte Declarative Connector framework (YAML) does not support dynamic field unnest (expanding a variable-length `__c` dictionary into separate rows) or proactive API quota inspection (`Sforce-Limit-Info` header reading). Custom field extraction and (optionally) budget-aware shutdown require Python components — either a custom `RecordExtractor` within the manifest or a full Python CDK connector
- Salesforce retains soft-deleted records in the Recycle Bin for 15 days by default; the `queryAll` endpoint with `IsDeleted = true` captures these deletions. Permanently purged records (beyond Recycle Bin retention) are invisible to all API endpoints
- The `salesforce_deleted_records` stream covers Contacts, Accounts, Opportunities, Tasks, and Events; it does not detect deleted Users (Salesforce users are deactivated, not deleted)
- `WhoId` and `WhatId` on Task and Event objects are polymorphic references; the object type can be derived from the Salesforce ID prefix (first 3 characters = `KeyPrefix` from Describe API) or via SOQL relationship queries
- `OpportunityFieldHistory` is available when Field History Tracking is enabled for the Opportunity object in Salesforce Setup; if not enabled, the connector emits an empty stream and logs a warning
- Salesforce API version is pinned per connection (default: latest stable at configuration time); Salesforce retires API versions ~3 years after release. The connector must be updated before the pinned version reaches end-of-life
- SOQL queries have a 100,000 character limit; custom field SELECT clauses for objects with hundreds of `__c` fields may need to be split into multiple queries
- Compound custom fields (Address, Geolocation types) return structured JSON objects instead of scalar values; these are serialized as JSON strings with `value_type = 'json'`
- Multi-currency orgs include `CurrencyIsoCode` on Opportunity and other amount-bearing objects; single-currency orgs return `null` or a uniform value
- Sandbox orgs have different login URLs (`test.salesforce.com`), lower API limits (typically 50% of production), and may contain stale copies of production data
- Field-Level Security (FLS) can make individual fields invisible to the API user without returning an error — the SOQL response simply omits the restricted field. The connector validates FLS coverage via the Describe API at configuration time
- `RecordTypeId` is available on Contacts, Accounts, and Opportunities; it determines picklist value sets and enables subcategory segmentation (e.g., "New Business" vs "Renewal" Opportunities)
- Salesforce returns `Sforce-Limit-Info: api-usage=N/M` in response headers on every successful API call; this is the only source of real-time API budget data

## 12. Risks

| Risk | Impact | Mitigation |
|------|--------|------------|
| API call limit exhaustion | Salesforce API limits are shared across all org integrations; exceeding the daily limit blocks other business-critical tools. Airbyte Declarative framework cannot proactively inspect quota headers — it retries on 403 and eventually fails the sync | Schedule runs during off-peak hours; monitor API call counts in collection run logs; alert operators on consumption trends. For proactive budget control, migrate to Python CDK (reads `Sforce-Limit-Info` headers). State checkpointing preserves cursor for committed pages — uncommitted pages are re-fetched on retry |
| Custom field schema drift | Customers add, rename, or remove `__c` fields between runs; ext tables may contain stale field references | Re-discover custom field metadata via Describe API at the start of each run; the key-value model is inherently tolerant of schema changes |
| Large Salesforce orgs (millions of records) | Initial full load may consume significant API calls and take extended time | Paginate with `queryMore`; support object-scoped extraction; implement resumable state for interrupted initial loads |
| Tasks vs Events Silver merge complexity | Two separate Bronze streams must be unified into `class_crm_activities` at Silver with shared semantics | Silver dbt model maps Task-specific fields (status, call_type) and Event-specific fields (duration, start_datetime) into a unified schema with `activity_type` discriminator. This is standard cross-source normalization, same as HubSpot engagement types |
| OAuth token expiration | Connected App refresh tokens can be revoked by admin or expire based on org policy | Implement token refresh with `refresh_token`; alert operator on authentication failures; support re-authorization flow |
| Profile.Name permission dependency | Relationship query for user profile requires elevated permissions; may fail silently | Emit `null` for profile field when unavailable; log warning; document permission requirements |
| Multi-org ID collisions | Multiple Salesforce orgs (production + sandbox) may have overlapping 18-char IDs for different records | Require `insight_source_id` in all joins; composite scope ensures unique identification |
| Soft-deleted records inflating pipeline | Standard SOQL excludes soft-deleted records; without deletion detection, deleted Opportunities remain "active" in Bronze, artificially inflating pipeline value | Dedicated `salesforce_deleted_records` stream via `queryAll` with `IsDeleted = true` captures soft-deletes day-to-day — see FR `cpt-insightspec-fr-sf-deleted-records`. Permanently purged records (after 15-day Recycle Bin retention) require periodic full reconciliation |
| Custom field unnest requires Python components | Declarative YAML cannot dynamically expand a variable-length `__c` field dictionary into separate key-value rows | DESIGN must specify the implementation path: custom `RecordExtractor`, hybrid manifest with Python components, or full Python CDK migration — see architectural constraints on FR `cpt-insightspec-fr-sf-opportunity-custom-fields` |
| `owner_id` references inactive users | Deactivated users still own historical records; the user directory must include inactive users | Extract all users regardless of `is_active` status; filter active/inactive at analytics layer |
| Field-Level Security (FLS) silently hiding fields | FLS-restricted fields are absent from SOQL responses with no error; critical fields like `Amount` or `Email` may be silently missing | Validate FLS coverage via Describe API at connection configuration (UC-001); log hidden fields in collection run log; emit `null` for missing fields — see FR `cpt-insightspec-fr-sf-fls-validation` |
| Sandbox data pollution | Sandbox orgs connected alongside production produce duplicate or stale records; API limits are lower (often 50% of production) | Detect sandbox vs. production at connection time via OAuth response / instance URL; label connections; warn operators about duplication risk |
| Bulk API not used for large orgs | REST API with `queryMore` consumes one API call per 2000-record page; initial loads of millions of records consume thousands of API calls | Documented as out of scope for v1.0. DESIGN should evaluate Bulk API 2.0 as an optimization for initial loads and large incremental deltas exceeding a configurable threshold |
| Email reuse on deactivated accounts | Departed employee deactivated → email reassigned to new hire → two `salesforce_users` records share the same email → Identity Manager merges them into one `person_id` | SCD Type 2 with `valid_from`/`valid_to` enables temporal disambiguation — see FR `cpt-insightspec-fr-sf-user-scd`. Identity Manager must use temporal bounds when resolving email-based identity |
| SOQL query character limit (100K chars) | Orgs with hundreds of custom fields on a single object may produce SELECT clauses approaching the 100K character limit | Split custom field SOQL queries into batches when the SELECT clause exceeds a safe threshold (e.g., 80K chars) — deferred to DESIGN |
| Polymorphic references (`WhoId`/`WhatId`) | Activity records reference Contacts, Leads, Accounts, Opportunities via polymorphic fields; without type discriminators, downstream joins require trial-and-error across all target tables | `who_type` and `what_type` discriminator fields derived from Salesforce ID prefix or relationship queries — see FR `cpt-insightspec-fr-sf-polymorphic-resolution` |
| Multi-currency amount aggregation | Orgs with Multi-Currency enabled store amounts in different currencies per Opportunity; summing amounts without `CurrencyIsoCode` produces incorrect pipeline totals | `currency_iso_code` collected on Opportunity records; Silver/Gold pipeline must normalize to a common currency before aggregation |
| API version deprecation | Salesforce retires API versions ~3 years after release; the connector pins a version at configuration time | Monitor Salesforce release calendar; update connector before pinned version reaches end-of-life; Describe API returns `deprecatedAndHidden` flags for sunset fields |
| OpportunityFieldHistory not enabled | Field History Tracking must be explicitly enabled per field in Salesforce Setup; if not enabled for `StageName`/`Amount`, the history stream is empty | Validate at configuration time (UC-001) via Describe API; warn operator if history tracking is disabled; log empty stream in collection run |

## 13. Resolved Questions

All open questions from the connector specification (`salesforce.md`) have been resolved and incorporated into the PRD as concrete requirements:

| ID | Summary | Resolution | Incorporated In |
|----|---------|------------|-----------------|
| OQ-SF-1 | Tasks vs Events — unified or separate Bronze tables | Separate Bronze streams: `salesforce_tasks` and `salesforce_events`. Each stream has its own schema (no nullable cross-type fields), its own `LastModifiedDate` cursor, and works natively in Airbyte Declarative YAML (one stream = one cursor). Tasks and Events are merged into `class_crm_activities` at the Silver layer via dbt. This follows the source-native 1:1 mapping principle (one Salesforce object = one Bronze table) and aligns with HubSpot's pattern (separate calls, meetings, tasks, emails streams). | FR `cpt-insightspec-fr-sf-task-extraction`, FR `cpt-insightspec-fr-sf-event-extraction` |
| OQ-SF-2 | Custom `__c` fields — collection scope | Whitelisted custom fields on Opportunity and Contact objects collected as key-value pairs in `salesforce_opportunity_ext` and `salesforce_contact_ext` tables. Field metadata discovered via Describe API. Only non-null values stored. Key-value model avoids schema changes per customer. | FR `cpt-insightspec-fr-sf-opportunity-custom-fields`, FR `cpt-insightspec-fr-sf-contact-custom-fields` |

## 14. Non-Applicable Requirements

The following checklist domains have been evaluated and determined not applicable for this connector:

| Domain | Reason |
|--------|--------|
| **Security (SEC)** | The connector handles OAuth tokens or username/password credentials, stored as `airbyte_secret` by the Airbyte framework. No custom authentication, authorization, or encryption logic exists in the connector. Credential storage and secret management are delegated to the Airbyte platform. |
| **Safety (SAFE)** | Pure data extraction pipeline. No interaction with physical systems, no potential for harm to people, property, or environment. |
| **Performance (PERF)** | Batch connector with native SOQL pagination (`queryMore`). No caching, pooling, or latency optimization needed. API call limit handling is the only performance concern, covered in FR `cpt-insightspec-fr-sf-api-limits`. |
| **Reliability (REL)** | Idempotent extraction via deduplication keys (Salesforce 18-char IDs). No distributed state, no transactions. Recovery is handled by re-running the sync (Airbyte framework manages state). |
| **Usability (UX)** | No user-facing interface. Configuration is a credential form and object scope selection in the Airbyte UI. No accessibility, internationalization, or inclusivity requirements apply. |
| **Compliance (COMPL)** | Salesforce user emails and contact emails are personal data under GDPR. Retention, deletion, and data subject rights are delegated to the Airbyte platform and destination operator. The connector must not store credentials outside the platform's secret management. |
| **Maintainability (MAINT)** | Initial implementation uses a hybrid approach: Declarative YAML for standard entity streams, with custom Python components (Record Extractor or Python CDK) for custom field unnest. Schema changes to standard streams are handled by updating field definitions in the manifest. Custom field collection uses the key-value pattern which is inherently extensible without manifest changes. |
| **Testing (TEST)** | Connector behavior must satisfy PRD acceptance criteria (Section 9). Validation includes: Airbyte framework connection check, schema validation, and connector-specific acceptance tests. No custom unit tests required — the declarative manifest is validated by the framework. |
