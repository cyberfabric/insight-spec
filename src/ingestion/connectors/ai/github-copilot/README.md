# GitHub Copilot Connector

Extracts seat assignments and per-user daily usage metrics from the GitHub REST API using a Personal Access Token with `manage_billing:copilot` scope.

The connector covers:
- **Seat roster** — who holds a Copilot seat, plan type, last activity timestamp, and primary editor
- **Per-user daily metrics** — code acceptance activity, lines of code added, and feature usage (IDE chat, agent mode, CLI) at daily granularity
- **Org-level daily metrics** — organization-wide aggregates (acceptance counts, lines added, active user counts, engagement breakdown)

## Specification

- **PRD**: [../../../../../docs/components/connectors/ai/github-copilot/specs/PRD.md](../../../../../docs/components/connectors/ai/github-copilot/specs/PRD.md)
- **DESIGN**: [../../../../../docs/components/connectors/ai/github-copilot/specs/DESIGN.md](../../../../../docs/components/connectors/ai/github-copilot/specs/DESIGN.md)

## Prerequisites

1. Organization must have GitHub Copilot for Business or Enterprise enabled.
2. An Organization Owner creates a Personal Access Token (classic) at github.com → Settings → Developer settings → Personal access tokens → Tokens (classic).
3. The token must have `manage_billing:copilot` scope. Only Organization Owners can create tokens with this scope; fine-grained PATs do not support it.
4. The metrics streams use a two-step HTTP pattern: the connector first fetches a signed download URL from `api.github.com`, then downloads NDJSON from `copilot-reports.github.com` without an `Authorization` header.

> **Note**: The old `/orgs/{org}/copilot/metrics` endpoint was decommissioned on 2026-04-02 and MUST NOT be used. This connector targets the replacement reports API (`/orgs/{org}/copilot/metrics/reports/*`).

## K8s Secret

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: insight-github-copilot-main
  namespace: data
  labels:
    app.kubernetes.io/part-of: insight
  annotations:
    insight.cyberfabric.com/connector: github-copilot
    insight.cyberfabric.com/source-id: github-copilot-main
type: Opaque
stringData:
  github_token: "ghp_CHANGE_ME"
  github_org: "my-org"
  # github_start_date: "2025-01-01"  # optional; default = 90 days ago
```

### Fields

| Field | Required | Description |
|-------|----------|-------------|
| `github_token` | Yes | Personal Access Token (classic) with `manage_billing:copilot` scope. Marked `airbyte_secret: true` — never logged. |
| `github_org` | Yes | GitHub organization slug (e.g. `my-company`). |
| `github_start_date` | No | Earliest date to collect user and org metrics from (YYYY-MM-DD). Default: 90 days ago. |

> `insight_source_id` is **not** a `stringData` field — it is injected from the `insight.cyberfabric.com/source-id` annotation on the Secret. Setting it in `stringData` has no effect.

### Automatically injected

These fields are added to every record by the connector — do **not** put them in the K8s Secret:

| Field | Source |
|-------|--------|
| `tenant_id` | `tenant_id` from tenant YAML (`connections/<tenant>.yaml`) |
| `insight_source_id` | `insight.cyberfabric.com/source-id` annotation on the K8s Secret |
| `data_source` | Always `insight_github_copilot` |
| `collected_at` | UTC ISO-8601 timestamp at extraction time |

### Local development

```bash
cp src/ingestion/secrets/connectors/github-copilot.yaml.example src/ingestion/secrets/connectors/github-copilot.yaml
# Fill in real values, then apply:
kubectl apply -f src/ingestion/secrets/connectors/github-copilot.yaml
```

## Streams

| Stream | Endpoint | Sync Mode | Cursor | Step | Pagination |
|--------|----------|-----------|--------|------|-----------|
| `copilot_seats` | `GET /orgs/{org}/copilot/billing/seats` | Full refresh | — | — | Offset (`page` + `per_page=100`) |
| `copilot_user_metrics` | `GET /orgs/{org}/copilot/metrics/reports/users-1-day?day=YYYY-MM-DD` → signed URL | Incremental | `day` | P1D | None (signed URL → NDJSON) |
| `copilot_org_metrics` | `GET /orgs/{org}/copilot/metrics/reports/organization-1-day?day=YYYY-MM-DD` → signed URL | Incremental | `day` | P1D | None (signed URL → NDJSON) |

A fourth Bronze table — `copilot_collection_runs` — is produced by the orchestrator (one row per pipeline run), not by Airbyte. The connector does not define it as a stream (Phase 1 deferral — consistent with `claude-admin`, `claude-enterprise`, and `confluence`).

### Metrics stream fetch pattern

For each day requested, the metrics streams:
1. Call `api.github.com` with the `Authorization: Bearer {token}` header to receive a `{"download_links": [...], "report_day": "YYYY-MM-DD"}` envelope.
2. Download NDJSON from each URL in `download_links` (hosted on `copilot-reports.github.com`) **without** an `Authorization` header — the URLs are pre-authenticated.
3. Parse each response line-by-line (each line is a separate JSON object).

### Identity Keys

- `copilot_seats.user_email` — primary identity key (one row per seat; work email from linked GitHub account)
- `copilot_user_metrics.login` — secondary identity key (GitHub username); resolved to `user_email` by joining with `copilot_seats.user_login` in the Silver staging model

## Silver Targets

Two Silver staging models are defined for this connector and run under the `tag:github-copilot` dbt selector:

- `copilot__ai_dev_usage` — feeds `class_ai_dev_usage` (per-user daily code acceptance, lines added, feature engagement alongside Cursor/Claude Code/Windsurf). Source: `copilot_user_metrics` joined with `copilot_seats` to resolve `login` → `user_email`.
- `copilot__ai_org_usage` — feeds `class_ai_org_usage` (org-level daily aggregates). Source: `copilot_org_metrics`. **Deferred** — `class_ai_org_usage` Silver view does not yet exist; model is tagged `silver:class_ai_org_usage` for future activation.

Silver-level `silver:class_*` tags will be added in a separate PR alongside the Silver framework changes.

## Operational Constraints

- **Rate limits**: 5,000 requests/hour per authenticated user (GitHub REST API primary rate limit). The connector implements exponential backoff on HTTP 429, honouring `Retry-After` and `X-RateLimit-Reset`.
- **Signed URLs expire**: the connector must download NDJSON immediately after receiving the signed URL envelope; URLs are not cached across runs.
- **No auth header on download**: the download request to `copilot-reports.github.com` **MUST NOT** include the `Authorization` header.
- **Copilot policy gating**: if the organization has disabled Copilot for specific teams or users, they do not appear in `copilot_user_metrics`. The seat roster remains complete.
- **Login→email mapping**: `copilot_user_metrics.login` is a GitHub username, not an email. Email is resolved in the Silver model via join with `copilot_seats`. If a user appears in metrics but not in seats (transient race condition), `user_email` is NULL; the row is retained in Bronze but excluded from Silver identity resolution.

## Validation

```bash
cypilot validate --artifact docs/components/connectors/ai/github-copilot/specs/PRD.md
cypilot validate --artifact docs/components/connectors/ai/github-copilot/specs/DESIGN.md
```

## Related

- Sibling AI dev tool connectors: `cursor`, `claude-admin` (Claude Code usage), `windsurf` — all feed `class_ai_dev_usage`.
- Git data connector for the same GitHub organization: `github-v2` — commits, PRs, reviews. Shares the same organization scope but uses a different PAT scope (`repo`).
