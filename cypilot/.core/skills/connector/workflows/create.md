---
name: connector-create
description: "Create a new Insight Connector package"
---

# Create Connector

Creates a complete Insight Connector package with all required files.

## Phase 1: Gather Information

Ask the user (skip questions where context already provides the answer):

```
[Q1] Category? (collaboration / hr-directory / git / task-tracking / crm / support / ai / wiki)
[Q2] Connector name? (short, lowercase, e.g. m365, bamboohr, jira)
[Q3] API base URL? (e.g. https://graph.microsoft.com/v1.0)
[Q4] Auth type? (oauth2_client_credentials / api_key / bearer / basic)
[Q5] API documentation URL? (optional — will fetch and analyze)
[Q6] What data streams should the connector extract? (e.g. users, activities, tickets)
```

## Phase 2: Research API (if docs URL provided)

1. Fetch API documentation via WebFetch
2. Identify: endpoints, auth flow, pagination pattern, rate limits
3. Identify: available fields per stream, primary keys, cursor fields
4. Summarize findings for user confirmation

## Phase 3: Create Package

### For nocode (`CONNECTOR_TYPE=nocode`):

Read the reference connector for patterns:
- `src/ingestion/connectors/collaboration/zoom/connector.yaml`
- `src/ingestion/connectors/collaboration/zoom/descriptor.yaml`

Create files:

#### 3.1 `connector.yaml` — Airbyte declarative manifest

The manifest MUST be compatible with Airbyte Builder (import/export without manual fixes).

**Manifest version**: Use `version: 7.0.4` for new connectors. Existing connectors may use older versions (e.g. 6.44.0, 6.60.9) — do NOT change their version unless upgrading. The version refers to the Airbyte CDK declarative schema version. Breaking changes between 6.x and 7.x:
- v7 requires `type: DeclarativeSource` at top level
- v7 field definitions use `type: AddedFieldDefinition` explicitly
- v7 schemas use `http://json-schema.org/schema#` (not `draft-07`)

**Top-level structure** (order matters for Builder compatibility):

```yaml
version: 7.0.4
type: DeclarativeSource

check:
  type: CheckStream
  stream_names:
    - <lightest_stream>

definitions:
  linked:
    ...

streams:
  - type: DeclarativeStream
    ...

concurrency_level:
  type: ConcurrencyLevel
  default_concurrency: 1

spec:
  ...

metadata:
  autoImportSchema:
    <stream_name>: true
```

**`definitions.linked` pattern** — Builder uses granular `$ref` linking, NOT whole-object refs:

```yaml
definitions:
  linked:
    HttpRequester:
      url_base: https://api.example.com/v1
      authenticator:
        type: BasicHttpAuthenticator
        username: "{{ config['<prefix>_api_key'] }}"
        password: x
      request_headers:
        Accept: application/json
    SimpleRetriever:
      paginator:
        type: NoPagination
```

Each stream references individual properties from `definitions.linked`:

```yaml
requester:
  type: HttpRequester
  url_base:
    $ref: "#/definitions/linked/HttpRequester/url_base"
  authenticator:
    $ref: "#/definitions/linked/HttpRequester/authenticator"
  request_headers:
    $ref: "#/definitions/linked/HttpRequester/request_headers"
  path: <stream_specific_path>
```

Do NOT put `error_handler` in `definitions.linked` — Builder strips linked error handlers. Error handling is either per-stream in the requester or handled by the runtime.

**Streams go at root level** (`streams:`), NOT under `definitions`. They reference definitions via `$ref`.

**`check` block** goes BEFORE `definitions`, at the top of the manifest (after version/type). Use the lightest stream for the health check.

**`transformations` with AddFields** — each field item MUST have `type: AddedFieldDefinition`:

```yaml
transformations:
  - type: AddFields
    fields:
      - type: AddedFieldDefinition
        path:
          - tenant_id
        value: "{{ config['insight_tenant_id'] }}"
      - type: AddedFieldDefinition
        path:
          - source_id
        value: "{{ config['insight_source_id'] }}"
      - type: AddedFieldDefinition
        path:
          - unique_key
        value: >-
          {{ config['insight_tenant_id'] }}-{{ config['insight_source_id']
          }}-{{ record['<primary_field>'] }}
```

Only inject: `tenant_id`, `source_id`, `unique_key`, and optionally `raw_data` for configurable streams. Do NOT add `_source` or `_extracted_at` — dbt models handle source tagging, and Airbyte auto-generates `_airbyte_extracted_at`.

**Schema rules** — must match Builder output format:

```yaml
schema_loader:
  type: InlineSchemaLoader
  schema:
    type: object
    $schema: http://json-schema.org/schema#
    properties:
      unique_key:
        type: string
      tenant_id:
        type:
          - string
          - "null"
      source_id:
        type:
          - string
          - "null"
      # ... source fields with [type, "null"] order
    required:
      - unique_key
    additionalProperties: true
```

Schema specifics:
- Use `http://json-schema.org/schema#` (Builder output), NOT `http://json-schema.org/draft-07/schema#`
- Type arrays: `[type, "null"]` not `["null", type]`
- MUST include `required: [unique_key]`
- MUST include `additionalProperties: true`
- **Dynamic-key objects**: when an object uses data-driven keys (dates, IDs, locales) instead of fixed field names, define it as `type: object` with `additionalProperties: true` and do NOT list sample keys in `properties` -- Builder's `autoImportSchema` will hardcode sample keys, which must be removed.

**BasicHttpAuthenticator warning**: when using `BasicHttpAuthenticator`, Builder auto-adds `username` and `password` to `spec.connection_specification`. These are Builder artifacts — they map from the authenticator config fields and should NOT be added to K8s Secrets. The real credential fields use source-specific prefixes (e.g. `bamboohr_api_key`).

MUST include:
- `check` block at the top with the lightest stream
- `definitions.linked` block with reusable components (auth, paginator) using granular `$ref`
- `streams` at root level with `transformations` containing `AddFields` (with `AddedFieldDefinition` type on each item)
- `concurrency_level` section
- `metadata` section with `autoImportSchema`
- `spec.connection_specification` with `insight_tenant_id` and `insight_source_id` as required fields
- All config fields with source-specific prefixes (e.g. `azure_*`, `github_*`, `jira_*`)
- `InlineSchemaLoader` with schema following Builder conventions (see above)
- Incremental sync with computed dates (no config params for start/end)

#### 3.2 `descriptor.yaml`

```yaml
name: <connector_name>
version: "1.0"

schedule: "0 2 * * *"
dbt_select: "tag:<connector_name>+"
workflow: sync

connection:
  namespace: "bronze_<connector_name>"
```

All streams from the manifest are synced. Sync mode is auto-detected by Airbyte discover (`incremental` if supported, otherwise `full_refresh`).

#### 3.3 K8s Secret example — `src/ingestion/secrets/connectors/<name>.yaml.example`

All connector credentials are stored as K8s Secrets, not inline in tenant YAML. Create the example file:

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: insight-<connector_name>-main
  labels:
    app.kubernetes.io/part-of: insight
  annotations:
    insight.cyberfabric.com/connector: <connector_name>
    insight.cyberfabric.com/source-id: <connector_name>-main
type: Opaque
stringData:
  <prefix>_field1: "CHANGE_ME"
  <prefix>_field2: "CHANGE_ME"
```

Rules:
- File goes to `src/ingestion/secrets/connectors/<name>.yaml.example` (committed to git)
- Real secrets go to `src/ingestion/secrets/connectors/<name>.yaml` (gitignored)
- Secret name pattern: `insight-<connector_name>-<source_id_suffix>`
- Labels: `app.kubernetes.io/part-of: insight`
- Annotations: `insight.cyberfabric.com/connector: <name>`, `insight.cyberfabric.com/source-id: <name>-main`
- `stringData` keys MUST match `spec.connection_specification` property names (with source-specific prefixes)
- Do NOT include `insight_tenant_id` or `insight_source_id` — these are injected by `connect.sh`
- Do NOT include `username`/`password` if using `BasicHttpAuthenticator` — these are Builder artifacts

#### 3.4 `README.md` — Connector documentation

```markdown
# <Connector Name> Connector

<One-line description of what data this connector extracts and the auth method.>

## Prerequisites

1. <How to get credentials from the source system>

## K8s Secret

\`\`\`yaml
<Full K8s Secret YAML — same as the .yaml.example>
\`\`\`

### Fields

| Field | Required | Description |
|-------|----------|-------------|
| `<prefix>_field` | Yes/No | <description> |

> **Note on `username` / `password` spec fields.** (only if BasicHttpAuthenticator)
> <explanation that these are Builder artifacts>

### Automatically injected

| Field | Source |
|-------|--------|
| `insight_tenant_id` | `tenant_id` from tenant YAML |
| `insight_source_id` | `insight.cyberfabric.com/source-id` annotation |

### Local development

Create `src/ingestion/secrets/connectors/<name>.yaml` (gitignored) from the example:

\`\`\`bash
cp src/ingestion/secrets/connectors/<name>.yaml.example src/ingestion/secrets/connectors/<name>.yaml
# Fill in real values, then apply:
kubectl apply -f src/ingestion/secrets/connectors/<name>.yaml
\`\`\`

## Streams

| Stream | Description | Sync Mode |
|--------|-------------|-----------|

## Silver Targets

- `class_<domain>` — <description>
```

#### 3.5 `dbt/<connector_name>__<domain>.sql`

```sql
{{ config(
    materialized='incremental',
    unique_key='unique_key',
    schema='staging',
    tags=['<connector_name>', 'silver:class_<domain>']
) }}

SELECT
    tenant_id,
    source_id,
    unique_key,
    -- source-specific field mappings
    '<connector_name>' AS source
FROM {{ source('<connector_name>', '<stream_name>') }}
{% if is_incremental() %}
WHERE <cursor_field> > (SELECT max(<mapped_field>) FROM {{ this }})
{% endif %}
```

#### 3.6 `dbt/schema.yml`

Define source (bronze database) and model with tests:
- `tenant_id`: not_null
- `source_id`: not_null
- `unique_key`: not_null, unique

### For CDK (`CONNECTOR_TYPE=cdk`):

Create Python scaffold:

#### 3.1 `src/source_<name>/__init__.py`
#### 3.2 `src/source_<name>/source.py`

```python
from airbyte_cdk.sources import AbstractSource

class Source<Name>(AbstractSource):
    def check_connection(self, logger, config):
        # Validate credentials
        ...

    def streams(self, config):
        tenant_id = config["insight_tenant_id"]
        source_id = config["insight_source_id"]
        return [
            Stream1(tenant_id=tenant_id, source_id=source_id, ...),
        ]
```

Each stream MUST inject `tenant_id`, `source_id`, `unique_key` in `parse_response()`:

```python
def parse_response(self, response, **kwargs):
    for record in response.json()["data"]:
        record["tenant_id"] = self.tenant_id
        record["source_id"] = self.source_id
        record["unique_key"] = f"{self.tenant_id}-{self.source_id}-{record['id']}"
        yield record
```

#### 3.3 `src/source_<name>/schemas/<stream>.json`
#### 3.4 `setup.py`
#### 3.5 `Dockerfile`
#### 3.6 Same descriptor.yaml, K8s Secret example, README.md, dbt/ as nocode

## Phase 4: Validate Package Structure

After creating all files, run:
```
/connector validate <name>
```

## Phase 5: Local Testing (MANDATORY before Airbyte)

All testing MUST happen locally first via `source.sh` before uploading to Airbyte.

**Airbyte Builder note**: after importing/exporting via Builder, expect these changes to the manifest:
- `username` and `password` fields added to `spec.connection_specification` (Builder artifact from `BasicHttpAuthenticator` — expected and harmless)
- Schema `$schema` normalized to `http://json-schema.org/schema#`
- Field types reordered to `[type, "null"]`
- `metadata.testedStreams` section added with stream hashes

These are normal Builder behaviors, not errors.

### 5.1 Create K8s Secret with credentials

```bash
cp src/ingestion/secrets/connectors/<name>.yaml.example src/ingestion/secrets/connectors/<name>.yaml
# Edit with real credential values
kubectl apply -f src/ingestion/secrets/connectors/<name>.yaml
```

### 5.2 Validate manifest structure (no API call)

```bash
./tools/declarative-connector/source.sh validate <category>/<name>
```

### 5.3 Check credentials against API

```bash
./tools/declarative-connector/source.sh check <category>/<name> <tenant>
```

### 5.4 Discover streams and generate schema from real data

```bash
./tools/declarative-connector/source.sh discover <category>/<name> <tenant>
./scripts/generate-schema.sh <name>
```

This saves real JSON schemas to `connectors/<category>/<name>/schemas/`.

### 5.5 Update manifest with real schema

Replace InlineSchemaLoader schemas in `connector.yaml` with the generated ones from `schemas/`.
Verify that all cursor fields exist in the schema (this prevents ClickHouse destination NPE).

### 5.6 Read data locally

```bash
./scripts/generate-catalog.sh <name>
./tools/declarative-connector/source.sh read <category>/<name> <tenant>
```

Verify every record has `tenant_id`, `source_id`, `unique_key`.

### 5.7 Only then deploy to Airbyte

```bash
/connector deploy <name>
```

## Phase 6: Summary

```
Connector package created and tested: src/ingestion/connectors/<category>/<name>/

Completed:
  ✓ Package structure validated
  ✓ K8s Secret created and applied
  ✓ Credentials checked against API
  ✓ Streams discovered, schema generated from real data
  ✓ Data read locally — all mandatory fields present

Next: /connector deploy <name>
```
