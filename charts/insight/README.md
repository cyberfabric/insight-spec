# Insight umbrella chart

Single canonical unit of delivery for the Insight platform.

- **Chart**: `insight`
- **Version**: see `Chart.yaml` → `version`
- **App version**: see `Chart.yaml` → `appVersion` (matches image tags)

## What it contains

| Component      | Kind        | Source                                       |
|----------------|-------------|----------------------------------------------|
| ClickHouse     | infra       | `helmfile/charts/clickhouse` (local wrapper) |
| MariaDB        | infra       | bitnami/mariadb ~20                          |
| Redis          | infra       | bitnami/redis ~21                            |
| Redpanda       | infra       | redpanda/redpanda ~5                         |
| API Gateway    | app service | `src/backend/services/api-gateway/helm`      |
| Analytics API  | app service | `src/backend/services/analytics-api/helm`    |
| Identity       | app service | `src/backend/services/identity/helm`         |
| Frontend (SPA) | app service | `src/frontend/helm`                          |

## What it does NOT contain

| Component        | Why separate                                          | How to install                 |
|------------------|-------------------------------------------------------|--------------------------------|
| Airbyte          | Heavy (10+ pods), its own release cadence             | Separate helm release          |
| Argo Workflows   | Cluster-scoped infra, often shared across products    | Separate helm release          |
| Plugins          | Runtime-managed via UI (not Helm — see architecture)  | Through platform API           |

See [`docs/distribution/README.md`](../../docs/distribution/README.md) for the full distribution model.

## Release name convention

**This chart assumes release name = `insight`.**

Internal DNS references (e.g. `http://insight-analytics-api:8081`, `http://insight-clickhouse:8123`) are hardcoded in `values.yaml` with the `insight-` prefix. Helm subcharts use `{{ .Release.Name }}-{chart-suffix}` for service naming, which produces these exact names when the release is `insight`.

If you install under a different name, override all cross-service URLs in your own values.yaml. Prefer sticking to the convention.

## Install (quickstart)

```bash
# 1. Pull & resolve subcharts into charts/insight/charts/
helm dependency update charts/insight

# 2. Dry-run — check that values compose cleanly
helm template insight charts/insight --namespace insight

# 3. Install
helm upgrade --install insight charts/insight \
  --namespace insight --create-namespace \
  -f my-values.yaml \
  --wait --timeout 10m
```

## Install (production checklist)

Before going to prod:

- [ ] Set secrets via `existingSecret` references, **never inline**:
  - `apiGateway.oidc.existingSecret`
  - `analyticsApi.clickhouse.credentialsSecret.name`
  - `identity.clickhouse.credentialsSecret.name`
- [ ] Override all `changeme` passwords: `clickhouse.auth.password`, `mariadb.auth.*`
- [ ] Enable ingress + TLS: `apiGateway.ingress`, `frontend.ingress`
- [ ] Bump resources where needed (default `requests` are conservative)
- [ ] `redpanda.tls.enabled: true`, `redpanda.auth.sasl.enabled: true`
- [ ] Point MariaDB/ClickHouse/Redis to external managed services if running inside Constructor Platform (set `enabled: false` on the subchart + fill `external.*` + override URLs in the app-service sections)
- [ ] Set `global.imagePullSecrets` if pulling from a private registry

## Integration modes

The chart supports two deployment shapes; the pattern is symmetric across every infra dependency (ClickHouse, MariaDB, Redis, Redpanda).

**Standalone** (eval, on-prem single-tenant, dev):
- `<infra>.enabled: true` — the umbrella deploys the dependency itself.
- App services connect to the internal DNS (`{release}-clickhouse`, etc.).

**Constructor Platform component** (required when Insight ships inside the platform):
- `<infra>.enabled: false` — the platform provides the dependency externally.
- Fill `<infra>.external.host` / `.port` / `.credentialsSecret.name`.
- App service URLs must be overridden to point at the external hosts (values are not templatable in Helm; see notes in `values.yaml`).

The umbrella validator (`templates/_helpers.tpl` → `insight.validate`) fails fast if `enabled: false` is set without a matching `external.host` — typos do not reach the cluster.

## Values reference

See comments in [`values.yaml`](./values.yaml) — every block is documented inline.

Key groups:

- `global.*` — cluster-wide defaults (pull secrets, storage class, bitnami image policy)
- `<infraname>.enabled` / `<infraname>.external.*` — toggle standalone vs Constructor Platform external
- `apiGateway` / `analyticsApi` / `identity` / `frontend` — mandatory app services (no enabled-flag; the gateway is the single entrance and the product is one unit)
- `apiGateway.oidc` — OIDC configuration (prefer `existingSecret`; inline requires `issuer` + `clientId` + `redirectUri` together)
- `apiGateway.proxy.routes` — reverse-proxy config to downstream services
- `ingestion.templates.enabled` — whether to ship Argo WorkflowTemplates; requires Argo CRDs to be present in the cluster

## Operations

```bash
# Status
helm -n insight status insight
kubectl -n insight get pods -l app.kubernetes.io/part-of=insight

# Upgrade (new appVersion → update image tags via -f values.yaml)
helm upgrade insight charts/insight -n insight -f my-values.yaml

# Rollback
helm -n insight rollback insight <REVISION>

# Uninstall (does NOT delete PVCs for stateful components — cleanup manually)
helm -n insight uninstall insight
kubectl -n insight delete pvc -l app.kubernetes.io/part-of=insight
```

## Subchart prerequisites (done as part of this change)

To make the umbrella compose cleanly, two subcharts were patched:

- `helmfile/charts/clickhouse` — added `clickhouse.fullname` helper so the Service is named `<release>-clickhouse`, not just `<release>`.
- `src/frontend/helm` — changed `insight-frontend.fullname` to append `-frontend`, so it doesn't collide with other resources that use bare `{release}`.

Both charts remain compatible with the existing Helmfile (`helmfile sync`) — they add a suffix that wasn't there before, so service names under Helmfile become `clickhouse-clickhouse` / `frontend-frontend`. If Helmfile references old names anywhere, update those too.

## Relationship to `helmfile.yaml.gotmpl`

| Concern           | `helmfile` (dev)                   | umbrella (distribution)            |
|-------------------|------------------------------------|------------------------------------|
| Audience          | Developers                          | Customers / GitOps                 |
| Invocation        | `helmfile -e local sync`            | `helm install insight charts/insight` |
| Templating        | gotmpl DSL                          | Pure Helm + YAML                   |
| Secret injection  | `.env.local` → helmfile vars        | `existingSecret` references        |
| Publishing        | Not published                       | OCI registry (`helm push`)          |

They coexist. Devs keep using Helmfile locally for fast iteration; distribution goes through the umbrella.

## Publishing (release workflow — not wired up yet)

```bash
# 1. Package
helm package charts/insight -d dist/

# 2. Push to OCI registry (ghcr.io example)
helm push dist/insight-0.1.0.tgz oci://ghcr.io/cyberfabric/charts

# 3. Customer install:
helm upgrade --install insight oci://ghcr.io/cyberfabric/charts/insight \
  --version 0.1.0 \
  --namespace insight --create-namespace \
  -f customer-values.yaml
```

Wire this up in GitHub Actions on tag `v*`. TODO separately.
