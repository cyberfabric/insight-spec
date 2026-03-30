---
status: accepted
date: 2026-03-30
---

# DESIGN -- Insight Connector Specification

<!-- toc -->

- [1. Key Concepts](#1-key-concepts)
- [2. Mandatory Record Fields](#2-mandatory-record-fields)
- [3. Config Field Naming Rules](#3-config-field-naming-rules)
- [4. Schema Rules](#4-schema-rules)
- [5. Connector Package Structure](#5-connector-package-structure)
- [6. Descriptor YAML Schema](#6-descriptor-yaml-schema)
- [7. Declarative Manifest (Nocode)](#7-declarative-manifest-nocode)
  - [7.1 Manifest Structure](#71-manifest-structure)
  - [7.2 Authentication Patterns](#72-authentication-patterns)
  - [7.3 Pagination Patterns](#73-pagination-patterns)
  - [7.4 Incremental Sync](#74-incremental-sync)
  - [7.5 AddFields (tenant_id + source_id + unique_key)](#75-addfields-tenant_id--source_id--unique_key)
  - [7.6 Record Extraction](#76-record-extraction)
  - [7.7 Request Parameters](#77-request-parameters)
- [8. CDK Connector (Python)](#8-cdk-connector-python)
- [9. Bronze Table Rules](#9-bronze-table-rules)
- [10. Silver Table Rules](#10-silver-table-rules)
- [11. dbt Model Rules](#11-dbt-model-rules)
- [12. Raw Data Field for Configurable Streams](#12-raw-data-field-for-configurable-streams)
- [13. Development Workflow](#13-development-workflow)
- [14. Common Pitfalls](#14-common-pitfalls)
- [15. Traceability](#15-traceability)

<!-- /toc -->

---

## 1. Key Concepts

**Insight Connector** -- a complete pipeline package consisting of:

- An **Airbyte Connector** (the extraction component)
- A **descriptor** (`descriptor.yaml`) declaring schedule, streams, Silver targets
- **dbt transformations** (Bronze to Silver models)
- A **credentials template** (`credentials.yaml.example`)

**Airbyte Connector** -- the extraction component that pulls data from a source API. Implemented as either:

- **Nocode** -- a declarative YAML manifest (`connector.yaml`) using Airbyte's low-code framework
- **CDK** -- a Python connector using Airbyte's Connector Development Kit (`AbstractSource` subclass)

Prefer nocode. Use CDK only when the declarative approach cannot express the required logic (multi-step auth, binary data, complex transformations, request chaining).

## 2. Mandatory Record Fields

Every record emitted by every connector MUST contain these fields:

| Field | Config parameter | Column in Bronze table | Purpose |
|-------|-----------------|------------------------|---------|
| `tenant_id` | `insight_tenant_id` | `tenant_id` | Tenant isolation -- all downstream layers depend on this |
| `source_id` | `insight_source_id` | `source_id` | Distinguish multiple instances of the same connector (e.g. two GitLab servers) |
| `unique_key` | Computed | `unique_key` | Composite deduplication key -- see below |

### unique_key

`unique_key` is a composite string that uniquely identifies a record within the platform. It MUST include `tenant_id` and `source_id` to avoid collisions between tenants and connector instances.

Pattern:

```
{{ config['insight_tenant_id'] }}-{{ config['insight_source_id'] }}-{{ record['field1'] }}-{{ record['field2'] }}
```

Real example (M365 email_activity):

```yaml
- path: [unique_key]
  value: "{{ config['insight_tenant_id'] }}-{{ config['insight_tenant_id'] }}-{{ config['insight_source_id'] }}-{{ record['userPrincipalName'] }}-{{ record['reportRefreshDate'] }}"
```

The fields composing the key depend on the source. Choose fields that together form a natural primary key in the source system.

## 3. Config Field Naming Rules

Config fields use prefixes to prevent collisions:

| Prefix | Usage | Examples |
|--------|-------|----------|
| `insight_*` | Platform fields (mandatory) | `insight_tenant_id`, `insight_source_id` |
| `azure_*` | Azure / M365 credentials | `azure_tenant_id`, `azure_client_id`, `azure_client_secret` |
| `github_*` | GitHub credentials | `github_token`, `github_org` |
| `jira_*` | Jira credentials | `jira_domain`, `jira_api_token`, `jira_email` |
| `bamboohr_*` | BambooHR credentials | `bamboohr_api_key`, `bamboohr_subdomain` |

Rules:

- `insight_tenant_id` and `insight_source_id` are ALWAYS required in `spec.connection_specification`
- Source-specific fields use a prefix matching the source name
- NEVER use bare `tenant_id`, `client_id`, or `source_id` in config -- always prefixed
- Secrets use `airbyte_secret: true` in the spec

Spec example:

```yaml
spec:
  type: Spec
  connection_specification:
    type: object
    $schema: http://json-schema.org/draft-07/schema#
    required:
      - insight_tenant_id
      - insight_source_id
      - azure_client_id
      - azure_client_secret
      - azure_tenant_id
    properties:
      insight_tenant_id:
        type: string
        title: Insight Tenant ID
        description: Tenant isolation identifier
        order: 0
      insight_source_id:
        type: string
        title: Insight Source ID
        description: Unique identifier for this connector instance
        order: 1
      azure_client_id:
        type: string
        title: Azure Client ID
        order: 2
      azure_client_secret:
        type: string
        title: Azure Client Secret
        airbyte_secret: true
        order: 3
      azure_tenant_id:
        type: string
        title: Azure Tenant ID
        order: 4
    additionalProperties: true
```

## 4. Schema Rules

### Generation

Schemas MUST be generated from real API data using:

```bash
./scripts/generate-schema.sh {name}
```

This saves per-stream JSON schemas to `schemas/{stream_name}.json`. These generated schemas are then used as the basis for the `InlineSchemaLoader` in the manifest.

### InlineSchemaLoader format

Use `InlineSchemaLoader` with explicit field definitions per [Airbyte schema reference](https://docs.airbyte.com/platform/connector-development/schema-reference):

```yaml
schema_loader:
  type: InlineSchemaLoader
  schema:
    type: object
    $schema: http://json-schema.org/schema#
    properties:
      tenant_id:
        type: string
      source_id:
        type: string
      unique_key:
        type: string
      reportRefreshDate:
        type: string
      userPrincipalName:
        type: [string, "null"]
      sendCount:
        type: [number, "null"]
    required:
      - unique_key
      - tenant_id
      - source_id
      - reportRefreshDate
    additionalProperties: true
```

Rules:

- `additionalProperties: true` on every schema for forward compatibility
- `tenant_id`, `source_id`, and `unique_key` are required string fields in every schema
- Use nullable types (`type: [string, "null"]`) only where the API actually returns null values. Do not make all fields nullable by default
- Do not invent fields -- derive from real API responses via `generate-schema.sh`

## 5. Connector Package Structure

```
connectors/{category}/{name}/
  connector.yaml              # Airbyte declarative manifest (nocode)
  descriptor.yaml             # Schedule, streams, dbt_select, workflow, connection config
  credentials.yaml.example    # Template: required credentials (tracked in repo)
  .env.local                  # Test credentials (gitignored)
  schemas/                    # Generated JSON schemas per stream
    {stream_name}.json
  dbt/
    to_{domain}.sql           # Bronze -> Silver model
    schema.yml                # Source + column docs + tests
  connections/
    dev/
      configured_catalog.json # For local testing
      state.json              # Incremental sync state
```

CDK connectors additionally contain:

```
connectors/{category}/{name}/
  src/
    source_{name}/
      __init__.py
      source.py               # AbstractSource implementation
      schemas/
        {stream}.json
    setup.py
    Dockerfile
```

### Credential Separation

Credentials are never stored in the connector package:

1. `credentials.yaml.example` documents required fields (tracked in repo)
2. Tenant admins create `connections/{tenant}.yaml` with real values (gitignored)
3. `.env.local` is for local testing only (gitignored)

```yaml
# connectors/collaboration/m365/credentials.yaml.example (tracked)
azure_tenant_id: ""       # Azure AD tenant ID
azure_client_id: ""       # App registration client ID
azure_client_secret: ""   # App registration client secret
```

## 6. Descriptor YAML Schema

Every Insight Connector package MUST include `descriptor.yaml`:

```yaml
name: m365
version: "1.0"
type: nocode                    # "nocode" or "cdk"

# Orchestration
schedule: "0 2 * * *"
workflow: sync
dbt_select: "tag:m365"

# Connection config (used by apply-connections.sh)
connection:
  namespace: "bronze_m365"
  streams:
    - name: email_activity
      sync_mode: full_refresh_overwrite
    - name: teams_activity
      sync_mode: full_refresh_overwrite

# Silver layer targets
silver_targets:
  - class_comms_events

# Stream definitions
streams:
  - name: email_activity
    bronze_table: email_activity
    primary_key: [unique_key]
    cursor_field: reportRefreshDate
  - name: teams_activity
    bronze_table: teams_activity
    primary_key: [unique_key]
    cursor_field: reportRefreshDate
```

Field reference:

| Field | Required | Description |
|-------|----------|-------------|
| `name` | Yes | Unique connector name |
| `version` | Yes | Package version |
| `type` | Yes | `nocode` or `cdk` |
| `schedule` | Yes | Cron expression for automated sync |
| `workflow` | Yes | Workflow template name |
| `dbt_select` | Yes | dbt selector for transformations |
| `connection.namespace` | Yes | ClickHouse database per connector (`bronze_{name}`, e.g. `bronze_m365`) |
| `connection.streams` | Yes | Streams to sync with their sync mode |
| `silver_targets` | Yes | Silver tables this connector populates |
| `streams` | Yes | Stream definitions with bronze_table, primary_key, cursor_field |

## 7. Declarative Manifest (Nocode)

### 7.1 Manifest Structure

Use `definitions` with `$ref` for reusable components:

```yaml
version: 7.0.4
type: DeclarativeSource

check:
  type: CheckStream
  stream_names: [email_activity]

definitions:
  linked:
    SimpleRetriever:
      paginator:
        # reusable paginator
    HttpRequester:
      request_body:
        # reusable auth body
      authenticator:
        # reusable auth config
      request_parameters:
        # reusable query params

streams:
  - type: DeclarativeStream
    name: email_activity
    primary_key: [unique_key]
    retriever:
      type: SimpleRetriever
      paginator:
        $ref: "#/definitions/linked/SimpleRetriever/paginator"
      record_selector:
        type: RecordSelector
        extractor:
          type: DpathExtractor
          field_path: [value]
      requester:
        type: HttpRequester
        http_method: GET
        authenticator:
          # ...
        request_parameters:
          $ref: "#/definitions/linked/HttpRequester/request_parameters"
        url: "https://graph.microsoft.com/beta/reports/getEmailActivityUserDetail(date={{ stream_slice.start_time }})"
    schema_loader:
      type: InlineSchemaLoader
      schema:
        # ...
    transformations:
      - type: AddFields
        fields:
          - path: [tenant_id]
            value: "{{ config['insight_tenant_id'] }}"
          - path: [source_id]
            value: "{{ config['insight_source_id'] }}"
          - path: [unique_key]
            value: "{{ config['insight_tenant_id'] }}-{{ config['insight_source_id'] }}-{{ record['userPrincipalName'] }}-{{ record['reportRefreshDate'] }}"
    incremental_sync:
      # ...

spec:
  type: Spec
  connection_specification:
    # ...
```

### 7.2 Authentication Patterns

| Pattern | When to use | Example |
|---------|------------|---------|
| OAuth2 client credentials | M365 Graph API | `SessionTokenAuthenticator` with `login_requester` |
| API key in header | Simple REST APIs | `ApiKeyAuthenticator` |
| Bearer token | Pre-generated tokens | `BearerAuthenticator` |
| Basic auth | Username/password APIs | `BasicHttpAuthenticator` |

M365 OAuth2 example:

```yaml
authenticator:
  type: SessionTokenAuthenticator
  login_requester:
    type: HttpRequester
    url: "https://login.microsoftonline.com/{{ config['azure_tenant_id'] }}/oauth2/v2.0/token"
    http_method: GET
    request_body:
      type: RequestBodyUrlEncodedForm
      value:
        scope: https://graph.microsoft.com/.default
        client_id: "{{ config['azure_client_id'] }}"
        grant_type: client_credentials
        client_secret: "{{ config['azure_client_secret'] }}"
  session_token_path: [access_token]
  expiration_duration: PT1H
  request_authentication:
    type: Bearer
```

### 7.3 Pagination Patterns

**OData `@odata.nextLink`** (M365, SharePoint):

```yaml
paginator:
  type: DefaultPaginator
  page_token_option:
    type: RequestPath
  pagination_strategy:
    type: CursorPagination
    cursor_value: "{{ response.get('@odata.nextLink', '') }}"
    stop_condition: "{{ not response.get('@odata.nextLink') }}"
```

**Offset/limit**:

```yaml
paginator:
  type: DefaultPaginator
  page_size_option:
    type: RequestOption
    inject_into: request_parameter
    field_name: limit
  page_token_option:
    type: RequestOption
    inject_into: request_parameter
    field_name: offset
  pagination_strategy:
    type: OffsetIncrement
    page_size: 100
```

**Cursor-based** (opaque token):

```yaml
paginator:
  type: DefaultPaginator
  page_token_option:
    type: RequestOption
    inject_into: request_parameter
    field_name: cursor
  pagination_strategy:
    type: CursorPagination
    cursor_value: "{{ response['next_cursor'] }}"
    stop_condition: "{{ not response.get('next_cursor') }}"
```

### 7.4 Incremental Sync

Use `DatetimeBasedCursor` with computed dates. Start and end dates are NEVER passed via config -- always computed from current date:

```yaml
incremental_sync:
  type: DatetimeBasedCursor
  cursor_field: reportRefreshDate
  datetime_format: "%Y-%m-%d"
  cursor_granularity: P1D
  start_datetime:
    type: MinMaxDatetime
    datetime: "{{ (today_utc() - duration('P27D')).strftime('%Y-%m-%d') }}"
    datetime_format: "%Y-%m-%d"
  end_datetime:
    type: MinMaxDatetime
    datetime: "{{ (today_utc() - duration('P2D')).strftime('%Y-%m-%d') }}"
    datetime_format: "%Y-%m-%d"
  step: P1D
  lookback_window: P0D
```

Rules:

- `step` should match API granularity (P1D for daily reports)
- `end_datetime` accounts for data lag (e.g., 2 days for MS Graph API)
- `lookback_window: P0D` to avoid re-fetching already-synced data
- `cursor_granularity` matches `step`

### 7.5 AddFields (tenant_id + source_id + unique_key)

Every manifest MUST include an `AddFields` transformation injecting all three mandatory fields:

```yaml
transformations:
  - type: AddFields
    fields:
      - type: AddedFieldDefinition
        path: [tenant_id]
        value: "{{ config['insight_tenant_id'] }}"
      - type: AddedFieldDefinition
        path: [source_id]
        value: "{{ config['insight_source_id'] }}"
      - type: AddedFieldDefinition
        path: [unique_key]
        value: "{{ config['insight_tenant_id'] }}-{{ config['insight_source_id'] }}-{{ record['userPrincipalName'] }}-{{ record['reportRefreshDate'] }}"
```

### 7.6 Record Extraction

For JSON APIs returning records inside a wrapper object (e.g., OData `value` array):

```yaml
record_selector:
  type: RecordSelector
  extractor:
    type: DpathExtractor
    field_path:
      - value
```

Adjust `field_path` for the source API: `["data"]`, `["results"]`, `["items"]`, etc.

### 7.7 Request Parameters

For APIs that return CSV by default, force JSON with a GET parameter:

```yaml
requester:
  type: HttpRequester
  request_parameters:
    $format: application/json
```

Use `application/json` (full MIME type), not `json`.

## 8. CDK Connector (Python)

### When to Use CDK

Use CDK when the declarative manifest cannot express:

- Multi-step authentication flows (OAuth2 with custom token exchange)
- Requests that depend on results of previous requests (discover then fetch)
- Binary data extraction or processing
- Complex record transformation logic beyond `AddFields`
- Rate limiting with complex backoff strategies
- WebSocket or streaming data sources

### Source Structure

```python
from airbyte_cdk.sources import AbstractSource
from airbyte_cdk.models import AirbyteStream

class Source{Name}(AbstractSource):
    def check_connection(self, logger, config) -> Tuple[bool, Optional[str]]:
        # Validate credentials and connectivity
        ...

    def streams(self, config) -> List[AirbyteStream]:
        tenant_id = config["insight_tenant_id"]
        source_id = config["insight_source_id"]
        return [
            Stream1(tenant_id=tenant_id, source_id=source_id, ...),
            Stream2(tenant_id=tenant_id, source_id=source_id, ...),
        ]
```

### Mandatory Fields in CDK

Every stream MUST inject `tenant_id`, `source_id`, and `unique_key` into every record:

```python
class Stream1(HttpStream):
    def __init__(self, tenant_id: str, source_id: str, **kwargs):
        super().__init__(**kwargs)
        self.tenant_id = tenant_id
        self.source_id = source_id

    def parse_response(self, response, **kwargs):
        for record in response.json()["data"]:
            record["tenant_id"] = self.tenant_id
            record["source_id"] = self.source_id
            record["unique_key"] = f"{self.tenant_id}-{self.source_id}-{record['id']}"
            yield record
```

The `spec.json` MUST include `insight_tenant_id` and `insight_source_id` as required properties:

```json
{
  "connectionSpecification": {
    "required": ["insight_tenant_id", "insight_source_id"],
    "properties": {
      "insight_tenant_id": {
        "type": "string",
        "title": "Insight Tenant ID",
        "order": 0
      },
      "insight_source_id": {
        "type": "string",
        "title": "Insight Source ID",
        "order": 1
      }
    }
  }
}
```

### Testing CDK Connectors

```bash
# Unit tests
cd src/ingestion/connectors/{category}/{name}/src
pytest tests/

# Integration test
python -m source_{name} check --config config.json
python -m source_{name} discover --config config.json
python -m source_{name} read --config config.json --catalog configured_catalog.json --state state.json
```

## 9. Bronze Table Rules

- Table names match Airbyte stream names (e.g., `email_activity`, `teams_activity`)
- Per-tenant database namespace: `bronze_{tenant_id}`
- ReplacingMergeTree with epoch ms versioning for deduplication

Every Bronze row contains:

| Column | Type | Source |
|--------|------|--------|
| `tenant_id` | String | Injected by connector via `AddFields` / `parse_response()` |
| `source_id` | String | Injected by connector via `AddFields` / `parse_response()` |
| `unique_key` | String | Computed by connector |
| `_airbyte_raw_id` | String | Airbyte deduplication key (auto-generated) |
| `_airbyte_extracted_at` | DateTime64 | Extraction timestamp (auto-generated) |
| Source-specific fields | Various | Preserved from source API response |

## 10. Silver Table Rules

- Naming: `class_{domain}` (e.g., `class_comms_events`, `class_people`, `class_commits`)
- `tenant_id` and `source_id` MUST be preserved from Bronze
- Add a `source` column identifying the connector (e.g., `'m365'`, `'github'`)
- dbt models use `source()` references to Bronze tables

Example Silver model:

```sql
-- connectors/collaboration/m365/dbt/to_comms_events.sql
{{ config(materialized='view') }}

SELECT
    tenant_id,
    source_id,
    e.userPrincipalName AS user_email,
    e.sendCount AS emails_sent,
    (COALESCE(t.privateChatMessageCount, 0)
     + COALESCE(t.teamChatMessageCount, 0)) AS messages_sent,
    CAST(e.reportRefreshDate AS Date) AS activity_date,
    'm365' AS source
FROM {{ source('bronze', 'email_activity') }} e
JOIN {{ source('bronze', 'teams_activity') }} t
    ON e.userPrincipalName = t.userPrincipalName
    AND e.reportRefreshDate = t.reportRefreshDate
WHERE e.tenant_id = t.tenant_id
  AND e.source_id = t.source_id
```

## 11. dbt Model Rules

- Per-connector models live in `connectors/{category}/{name}/dbt/`
- Shared union models (combining multiple connectors into one Silver table) live in `dbt/silver/`
- Tags: `tag:{connector_name}` for selective execution via `dbt run --select tag:m365`
- `tenant_id` `not_null` test is required on every model

schema.yml example:

```yaml
version: 2

sources:
  - name: bronze
    schema: raw
    tables:
      - name: email_activity
      - name: teams_activity

models:
  - name: to_comms_events
    description: "M365 communication events (Bronze -> Silver)"
    columns:
      - name: tenant_id
        description: "Tenant isolation field"
        tests:
          - not_null
      - name: source_id
        description: "Source instance identifier"
        tests:
          - not_null
      - name: user_email
        description: "User email (source-native identifier)"
      - name: activity_date
        description: "Date of activity"
        tests:
          - not_null
```

## 12. Raw Data Field for Configurable Streams

For sources where fields are tenant-configurable (e.g., BambooHR custom fields):

- Unpack known/standard fields as top-level columns in the schema
- Add a `raw_data` field (type: `object`) containing the full original API response
- This allows downstream consumers to access any field without schema changes

```yaml
properties:
  tenant_id:
    type: string
  source_id:
    type: string
  unique_key:
    type: string
  employee_id:
    type: [string, "null"]
  first_name:
    type: [string, "null"]
  last_name:
    type: [string, "null"]
  raw_data:
    type: [object, "null"]
    description: "Full API response for accessing custom/tenant-specific fields"
additionalProperties: true
```

## 13. Development Workflow

| Step | Command | What it does |
|------|---------|-------------|
| 1 | Create directory | `connectors/{category}/{name}/` with `connector.yaml`, `descriptor.yaml`, `credentials.yaml.example` |
| 2 | Write manifest | Use `definitions` + `$ref` pattern. Include AddFields for `tenant_id`, `source_id`, `unique_key` |
| 3 | Create `.env.local` | Copy from `credentials.yaml.example`, fill in test values |
| 4 | Validate | `./tools/declarative-connector/source.sh validate {cat}/{name}` |
| 5 | Check | `./tools/declarative-connector/source.sh check {cat}/{name}` |
| 6 | Discover | `./tools/declarative-connector/source.sh discover {cat}/{name}` |
| 7 | Generate schema | `./scripts/generate-schema.sh {name}` -- saves to `schemas/` |
| 8 | Read | `./tools/declarative-connector/source.sh read {cat}/{name} dev` |
| 9 | Verify | Every record has `tenant_id`, `source_id`, `unique_key` |
| 10 | Upload | `./update-connectors.sh` |

### Credentials File (.env.local)

```bash
AIRBYTE_CONFIG='{"insight_tenant_id":"acme","insight_source_id":"m365-prod","azure_tenant_id":"63b4c45f-...","azure_client_id":"309e3a13-...","azure_client_secret":"G2x8Q~..."}'
```

### Local Testing Commands

```bash
# Validate manifest structure (no credentials needed)
./tools/declarative-connector/source.sh validate collaboration/m365

# Check connectivity
./tools/declarative-connector/source.sh check collaboration/m365

# Discover available streams
./tools/declarative-connector/source.sh discover collaboration/m365

# Read data
./tools/declarative-connector/source.sh read collaboration/m365 dev

# Pipe to destination for integration testing
./tools/declarative-connector/source.sh read collaboration/m365 dev | \
  ./destination.sh clickhouse bronze_test configured_catalog.json
```

## 14. Common Pitfalls

| Problem | Cause | Fix |
|---------|-------|-----|
| `no stream slices were found` | `start_date` in future or after `end_date` | Fix date computation in `incremental_sync` |
| `json is not a valid format value` | `$format=json` instead of `$format=application/json` | Use full MIME type: `application/json` |
| `Unexpected UTF-8 BOM` | API returns CSV with BOM instead of JSON | Add `$format: application/json` to `request_parameters` |
| `Validation against declarative_component_schema.yaml schema failed` | Invalid manifest structure | Check error details for the specific invalid field |
| `AIRBYTE_CONFIG is not valid JSON` | `.env.local` has shell-escaped quotes | Use raw JSON without surrounding shell quotes |
| Builder UI shows wrong test values after upload | Airbyte rebuilds test config from spec on manifest update | Re-enter test values manually in Builder UI |
| Records missing `tenant_id` | Forgot `AddFields` transformation | Add `AddFields` with `insight_tenant_id` to every stream |
| Duplicate records across instances | `unique_key` does not include `tenant_id` + `source_id` | Prefix `unique_key` with `config['insight_tenant_id']` + `config['insight_source_id']` |
| Config collision (`tenant_id` ambiguous) | Bare field name without prefix | Use `insight_tenant_id`, `azure_tenant_id`, etc. |

## 15. Traceability

| Design Element | PRD Requirement |
|---------------|----------------|
| Declarative manifest architecture | `cpt-insightspec-fr-ing-nocode-connector` |
| CDK connector architecture | `cpt-insightspec-fr-ing-cdk-connector` |
| `tenant_id` + `source_id` injection patterns | `cpt-insightspec-fr-ing-tenant-id` |
| Connector package structure | `cpt-insightspec-fr-ing-package-structure` |
| Monorepo storage | `cpt-insightspec-fr-ing-package-monorepo` |
| Incremental sync patterns | `cpt-insightspec-fr-ing-incremental-sync` |
| Secret management in `.env.local` | `cpt-insightspec-fr-ing-secret-management` |
| Airbyte API registration | `cpt-insightspec-fr-ing-airbyte-api-custom` |
| `unique_key` with `source_id` | `cpt-insightspec-nfr-ing-idempotency` |
| Per-tenant namespace isolation | `cpt-insightspec-nfr-ing-tenant-isolation` |

Related documents:

- **Ingestion PRD**: [../../ingestion/specs/PRD.md](../../ingestion/specs/PRD.md)
- **Ingestion DESIGN**: [../../ingestion/specs/DESIGN.md](../../ingestion/specs/DESIGN.md)
- **Connector README**: [../README.md](../README.md)
