# PRD -- Identity Resolution

## 1. Overview

### 1.1 Purpose

Identity Resolution maps identity signals from all connected source systems (BambooHR, Zoom, GitLab, Jira, Slack, etc.) into unified person records. It is a human-in-the-loop system: connectors emit identity observations automatically, the system generates matching proposals, and operators confirm or reject them.

### 1.2 Background / Problem Statement

Insight connects to 10+ external platforms. Each platform has its own user model: BambooHR has employees with workEmail and employeeNumber, Zoom has users with email and display_name, GitLab has users with username and email. The same real person often appears in multiple systems with different identifiers and sometimes different field values (e.g., personal email in one system, corporate email in another).

**Key problems solved**:
- **No unified identity**: Without identity resolution, analytics queries cannot correlate activity across systems for the same person
- **Silent wrong merges**: Automated email-based matching produces false positives (shared mailboxes, name collisions). All matches must be operator-confirmed
- **No temporal awareness**: Employee turnover means email addresses get recycled. Aliases must have start/end dates
- **Irreversible merges**: If two profiles are wrongly merged, the system must support splitting them without losing historical data

### 1.3 Goals

| Goal | Success Criteria |
|---|---|
| Unified person identity | 100% of cross-system analytics queries use identity-resolved person_id |
| Zero false-positive merges | All alias-to-person assignments are operator-confirmed; no automatic linking |
| Temporal correctness | Person state queryable at any historical date; merge/split does not alter past data |
| Reversible operations | Any merge can be split; any link can be unlinked; history preserved |

### 1.4 Glossary

| Term | Definition |
|---|---|
| Source profile | A user account in an external system, identified by (source_type, profile_id) |
| Identity input | A single field observation from a source profile: (field_type, field_value, observed_at) |
| Proposal | A system-generated suggestion for the operator: new unlinked profile, email match, or deactivation |
| Link | An operator decision binding a source profile to a person_id, with a timestamp |
| Person | A unified identity, represented as a vertical history of fields from linked source profiles |
| Merge | Moving a source profile's link from one person to another |
| Split | Reversing a merge: moving a source profile's link back to its original person |
| Deactivation | A DELETE operation from a connector indicating a field is no longer valid (e.g., employee terminated) |

## 2. Actors

### 2.1 Human Actors

| Actor | Role |
|---|---|
| Platform Operator | Reviews proposals, creates/updates links, performs merge/split operations |
| Analytics Consumer | Queries person data via identity_person table; uses person_id in reports |

### 2.2 System Actors

| Actor | Role |
|---|---|
| Connectors (Airbyte + dbt) | Emit identity observations into staging.*__identity_input tables |
| dbt Pipeline | Generates proposals from identity_input; materializes identity_person from input + links |

## 3. Scope

### 3.1 In Scope

- Collection of identity field observations from all connectors (email, display_name, employee_id, username, platform_id)
- Automatic detection of cross-system matches (same email in different sources)
- Proposal generation for operator review
- Operator workflow: link, unlink, merge, split
- Temporal person field history (append-only, queryable at any date)
- Incremental processing (no full rebuilds)

### 3.2 Out of Scope

- Automatic alias creation (all aliases are operator-confirmed)
- Fuzzy matching / ML-based matching (future phase)
- Golden record assembly and source-priority rules (Person domain)
- Org hierarchy (Org-Chart domain)
- GDPR hard deletion (future phase)
- Batch approve UI (future phase; MVP is one-by-one via SQL)

## 4. Functional Requirements

### 4.1 Identity Input Collection (p1)

Each connector provides a dbt model `{connector}__identity_input` that extracts identity-relevant fields from its fields_history using the `identity_input_from_history` macro. Fields include: email, display_name, employee_id, username, platform_id. Operations: UPSERT (field changed) and DELETE (entity deactivated).

All connector identity_input models are unioned into `identity.identity_input` VIEW via `union_by_tag('identity:input')`.

### 4.2 Proposal Generation (p1)

The system generates proposals by comparing identity_input data:
- **new_profile**: A source profile exists in identity_input but has no link in identity.links
- **email_match**: Two profiles from different sources share the same email address
- **deactivation**: A DELETE operation received from a connector

Proposals are incremental (only new observations generate new proposals) and deduplicated.

### 4.3 Operator Link Management (p1)

Operators create links binding source profiles to persons:
- **Create new person**: Generate a new person_id, link a profile to it
- **Link to existing person**: Link a profile to an already-existing person_id
- **Unlink**: Remove a profile's binding (sets profile_id = NULL)
- **Merge**: Unlink profile from person A + link to person B (two rows, one INSERT)
- **Split**: Reverse of merge (unlink from B + link back to A)

All operations are append-only in identity.links.

### 4.4 Person Field Materialization (p1)

When links change or new input data arrives, `identity_person` dbt model appends new field rows:
- **Link event**: All current input fields for the linked profile are written to identity_person with valid_from = link timestamp
- **Unlink event**: All fields the person had from that source are nullified (empty field_value) with valid_from = unlink timestamp
- **New input data**: When a connector syncs new data for an already-linked profile, the new field values are appended with valid_from = observed_at

Current person state: `argMax(field_value, valid_from)` grouped by (person_id, field_type, field_source), filtering out empty values.

### 4.5 Temporal Queries (p1)

Person state at any historical date is queryable by filtering `valid_from <= target_date` before aggregation. Merge/split operations do not alter past rows -- they only append new rows with later valid_from timestamps.

## 5. Non-Functional Requirements

| NFR | Target |
|---|---|
| Incremental processing | Each dbt run processes only new data since last run; no full table scans for writes |
| Idempotency | Repeated dbt runs with no new data produce no new rows |
| Append-only storage | No UPDATE or DELETE on identity.links, identity.identity_person, or identity.identity_proposals |
| Query performance | Current person state query < 100ms for single person_id |

## 6. Dependencies

| Dependency | Description |
|---|---|
| Connector fields_history models | Each connector must provide `staging.*_fields_history` for identity_input_from_history macro |
| ClickHouse | All tables stored in ClickHouse (MergeTree family) |
| dbt + dbt-clickhouse adapter | All transformations via dbt |
| Operator access to ClickHouse | MVP: operator runs SQL directly; future: UI |
