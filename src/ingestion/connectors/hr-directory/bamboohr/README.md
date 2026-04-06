# BambooHR Connector

Employee directory, leave requests, and field metadata from BambooHR via API Key authentication.

## Prerequisites

1. Log in to BambooHR as an admin
2. Go to **Account > API Keys** and generate a new API key
3. Note your BambooHR subdomain (e.g., `acme` from `acme.bamboohr.com`)

## K8s Secret

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: insight-bamboohr-main
  labels:
    app.kubernetes.io/part-of: insight
  annotations:
    insight.cyberfabric.com/connector: bamboohr
    insight.cyberfabric.com/source-id: bamboohr-main
type: Opaque
stringData:
  bamboohr_api_key: ""                      # BambooHR API key
  bamboohr_domain: ""                       # Subdomain (e.g. "acme")
  bamboohr_employees_custom_fields: "[]"    # Optional: JSON array of custom field aliases
```

### Fields

| Field | Required | Description |
|-------|----------|-------------|
| `bamboohr_api_key` | Yes | BambooHR API key (Account > API Keys) |
| `bamboohr_domain` | Yes | BambooHR subdomain (e.g. `acme` from `acme.bamboohr.com`) |
| `bamboohr_employees_custom_fields` | No | JSON array of custom field aliases (e.g. `["customTeam", "customProjects"]`) |
| `bamboohr_start_date` | No | Leave requests history start date, ISO format (default: `2020-01-01`) |

> **Note on `username` / `password` spec fields.**
> The Airbyte Builder auto-generates `username` and `password` properties in
> `connection_specification` because the connector uses `BasicHttpAuthenticator`.
> These are managed automatically by the authenticator config:
> `username` = `bamboohr_api_key`, `password` = `"x"` (hardcoded).
> Do **not** set them in the K8s Secret or credentials file -- they are not
> user-provided values.

### Automatically injected

| Field | Source |
|-------|--------|
| `insight_tenant_id` | `tenant_id` from tenant YAML |
| `insight_source_id` | `insight.cyberfabric.com/source-id` annotation |

### Local development

Create `src/ingestion/secrets/connectors/bamboohr.yaml` (gitignored) from the example:

```bash
cp src/ingestion/secrets/connectors/bamboohr.yaml.example src/ingestion/secrets/connectors/bamboohr.yaml
# Fill in real values, then apply:
kubectl apply -f src/ingestion/secrets/connectors/bamboohr.yaml
```

## Streams

| Stream | Description | Sync Mode |
|--------|-------------|-----------|
| `employees` | Employee directory via custom report API | Full refresh |
| `leave_requests` | Time-off requests (from 2020-01-01) | Full refresh |
| `meta_fields` | Field metadata (names, types, aliases) | Full refresh |

## Silver Targets

- `class_people` — unified person registry
