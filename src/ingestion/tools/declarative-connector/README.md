# declarative-connector — local manifest runner

Runs Airbyte declarative-manifest connectors in Docker without the full Airbyte platform. Used for rapid manifest development, validation, and local end-to-end smoke tests before uploading to Airbyte.

## Commands

| Command | Needs creds? | When to use |
|---|---|---|
| `./source.sh validate <class>/<connector>` | no | CDK-runtime validation. Resolves `$ref` before checking. **Lenient** — passes manifests the Builder UI rejects. |
| `./source.sh validate-strict <class>/<connector>` | no | **Strict** Builder-UI validation — runs the manifest through `declarative_component_schema.yaml` **without `$ref` resolution**, emitting per-path errors. Run this **before** opening the manifest in the Airbyte Builder UI. |
| `./source.sh check <class>/<connector> <tenant>` | yes | Manifest + credentials smoke test against the source API. |
| `./source.sh discover <class>/<connector> <tenant>` | yes | List available streams and their schemas. |
| `./source.sh read <class>/<connector> <tenant>` | yes | Extract data (Airbyte Protocol JSON on stdout). |

`<class>/<connector>` is relative to `src/ingestion/connectors/`, e.g. `collaboration/m365` or `task-tracking/youtrack`.

## Validation ladder — always in this order

1. **`validate-strict`** — first. Catches Builder UI blockers (`$ref` misuse, missing `type: AddedFieldDefinition`, templated integer fields, bad `$schema` URL, etc.) early, before runtime wastes a round trip.
2. **`validate`** — second. Smoke-checks that the CDK loader accepts the manifest at runtime, after `$ref` resolution.
3. **`check <tenant>`** — third. Real credentials against the real API. Catches query-syntax errors and auth problems.
4. **`discover` / `read`** — fourth. Produces real records locally; feeds `generate-schema.sh`.

If any step in the ladder fails, fix the issue and restart from step 1. **Do not skip ahead** — a manifest that fails `validate-strict` may still pass `validate` but cannot be edited in the Builder UI.

## Builder-UI compatibility — hard rules

The Airbyte Builder UI validates manifests against `declarative_component_schema.yaml` with **no `$ref` resolution**. A manifest can load fine via the CDK and still be rejected by the Builder. Keep these rules in mind when authoring manifests or when copying from another connector package:

### Rule 1 — No whole-object `$ref`

❌ **Forbidden** (the `task-tracking/jira` manifest uses this pattern — **do not copy from it**):

```yaml
requester:
  $ref: "#/definitions/base_requester"
paginator:
  $ref: "#/definitions/paginator"
```

```yaml
parent_stream_configs:
  - stream:
      $ref: "#/streams/4"        # substream-parent-by-ref
```

```yaml
transformations:
  - $ref: "#/definitions/add_fields"   # transformation-by-ref
```

✅ **Allowed** — granular, field-level `$ref` into `definitions.linked.<Component>/<field>`:

```yaml
definitions:
  linked:
    HttpRequester:
      url_base: https://api.example.com/v1
      authenticator:
        type: BasicHttpAuthenticator
        username: "{{ config['example_api_key'] }}"
        password: x
      request_headers:
        Accept: application/json

streams:
  - type: DeclarativeStream
    retriever:
      requester:
        type: HttpRequester
        url_base:
          $ref: "#/definitions/linked/HttpRequester/url_base"
        authenticator:
          $ref: "#/definitions/linked/HttpRequester/authenticator"
        request_headers:
          $ref: "#/definitions/linked/HttpRequester/request_headers"
        path: /widgets
```

For anything that cannot be expressed as a leaf-field `$ref` (full requester, paginator, retriever, stream), **inline the full definition** or duplicate it across streams. Repetition is the price of Builder compatibility.

### Rule 2 — `type: AddedFieldDefinition` on every `AddFields.fields[]` item

```yaml
transformations:
  - type: AddFields
    fields:
      - type: AddedFieldDefinition          # MANDATORY — Builder will reject without it
        path: [tenant_id]
        value: "{{ config['insight_tenant_id'] }}"
      - type: AddedFieldDefinition
        path: [source_id]
        value: "{{ config['insight_source_id'] }}"
```

### Rule 3 — Integer-typed fields must be literal integers, not templates

`OffsetIncrement.page_size`, `CursorPagination.page_size`, `concurrency_level.default_concurrency`, etc. are typed as `integer` in the schema. Templates fail the Builder validator silently.

❌ `page_size: "{{ config.get('my_page_size', 50) }}"`
✅ `page_size: 50`

If you need page-size to be tenant-configurable, parameterize via CI-time manifest generation or switch to a Python CDK, not a template in a declarative manifest.

### Rule 4 — Schema URL

Use `http://json-schema.org/schema#`, not `http://json-schema.org/draft-07/schema#`. This is what the Builder emits on export.

### Rule 5 — Schema type arrays ordered `[type, "null"]`

✅ `type: [string, "null"]`
❌ `type: ["null", string]`

### Rule 6 — Required top-level shape

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
  type: Spec
  connection_specification:
    required:
      - insight_tenant_id
      - insight_source_id
      - <source_api_fields>
    properties: ...

metadata:
  autoImportSchema: {...}
```

The `check` block goes **before** `definitions`. Use the cheapest stream (e.g. the directory list) so the health-check has minimal side effects.

## Anti-template: `task-tracking/jira`

The jira connector works at runtime but **fails the Builder UI strict validator** because it uses whole-object `$ref` for `auth`, `base_requester`, `paginator`, substream parents, and `add_fields`. Do not copy from it. Use `collaboration/zoom`, `collaboration/m365`, or `hr-directory/bamboohr` as structural references when authoring a Builder-compatible manifest.

Existing connectors that open cleanly in the Builder UI:

- `collaboration/zoom`
- `collaboration/m365`
- `hr-directory/bamboohr`

Connectors that **do not** open cleanly:

- `task-tracking/jira` — pre-Builder-compat; migrate to granular `$ref` when touching the file.

## Datetime syntax pitfalls

### YouTrack `updated` query

- Format MUST be ISO 8601 with `T` separator: `2026-01-01T00:00:00`
- No braces, no spaces: `updated: 2026-01-01T00:00:00 .. 2026-04-23T00:00:00 sort by: updated asc`
- Braces around datetimes (`updated: {2026-01-01T00:00:00} ..`) are rejected by YouTrack Cloud with `invalid_query`. They worked in legacy v1 because the server was older.

### Jira JQL

- Format: `YYYY-MM-DD HH:MM` (space separator, no seconds, no T)
- `updated >= "2024-01-01 00:00" AND updated <= "2024-02-01 00:00" ORDER BY updated ASC`

Each API has its own datetime dialect. Always confirm with `source.sh check <tenant>` against a real instance before trusting the manifest.

### Epoch millisecond cursors (e.g. YouTrack `updated`)

Some APIs return the cursor field as epoch milliseconds (YouTrack `updated` is an integer ms). **Do not try to convert via a transformation** — `format_datetime(record['x'] / 1000, ...)` inside an `AddedFieldDefinition.value` does not reliably render before the cursor observes the record, and you will see runtime errors like:

```
ValueError: No format in ['%Y-%m-%dT%H:%M:%S'] matching {{ format_datetime(record['updated'] / 1000, '%Y-%m-%dT%H:%M:%S') }}
```

(The value stays as the literal Jinja template.)

**Use Airbyte's native epoch formats** in `DatetimeBasedCursor.cursor_datetime_formats`:

| Token | Meaning |
|---|---|
| `%s` | epoch seconds |
| `%s_as_float` | epoch seconds (float, sub-second precision) |
| `%ms` | epoch **milliseconds** |
| `%epoch_microseconds` | epoch microseconds |

For YouTrack `updated` (millis), the cursor block is:

```yaml
incremental_sync:
  type: DatetimeBasedCursor
  cursor_field: updated                      # raw record field, no transform
  cursor_datetime_formats:                   # parse record value as %ms
    - '%ms'
    - '%Y-%m-%dT%H:%M:%S'                    # also accept ISO for persisted state
  datetime_format: '%Y-%m-%dT%H:%M:%S'       # format used for state + request params
  start_datetime:
    type: MinMaxDatetime
    datetime: "{{ config.get('x_start_date', '2020-01-01') }}T00:00:00"
    datetime_format: '%Y-%m-%dT%H:%M:%S'
  end_datetime:
    type: MinMaxDatetime
    datetime: "{{ now_utc().strftime('%Y-%m-%dT%H:%M:%S') }}"
    datetime_format: '%Y-%m-%dT%H:%M:%S'
  step: P30D
  lookback_window: PT1H
```

Keep both `%ms` (for live record values) and `%Y-%m-%dT%H:%M:%S` (for persisted state values re-parsed on resume) in `cursor_datetime_formats`.

## Debugging strict-validation errors

`validate-strict` prints the deepest-matching JSON-schema path for each error. Interpret like this:

```
[1] streams/0/transformations/0/fields/3: 'type' is a required property
```

→ `streams[0].transformations[0].fields[3]` is missing `type: AddedFieldDefinition`.

```
[1] streams/0/retriever/requester: 'type' is a required property
```

→ The `requester` is a `$ref` (opaque to the Builder validator). Inline or use granular leaf-field `$ref`.

```
[1] streams/0/retriever/paginator/pagination_strategy/page_size: 50 is not of type 'integer'
```

→ `page_size` was a template string. Make it a literal int.

If you need raw validator output with all alternative branches, invoke manually:

```bash
docker run --rm \
  -v "$PWD/src/ingestion/connectors/<class>/<connector>:/input:ro" \
  --entrypoint=/bin/sh \
  airbyte/source-declarative-manifest:local \
  -c 'python3 -c "import yaml, jsonschema; s=yaml.safe_load(open(\"/usr/local/lib/python3.13/site-packages/airbyte_cdk/sources/declarative/declarative_component_schema.yaml\")); m=yaml.safe_load(open(\"/input/connector.yaml\")); [print(e) for e in jsonschema.Draft7Validator(s).iter_errors(m)]"'
```
