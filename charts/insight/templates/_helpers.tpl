{{/*
==============================================================================
 Umbrella helpers
==============================================================================
Central place for:
  - release/component names (DRY)
  - service reference resolution (internal vs external) via enabled-gate
  - fail-fast validators for required fields

Any template that needs a dependency host/port/URL uses a helper rather
than hardcoding the name. If SRE ever decides to rename a component,
only this file changes.

No helper emits a silent default — missing values fail the render with
a readable message. Defaults in helpers hide typos and lead to mysterious
runtime failures.
==============================================================================
*/}}

{{- define "insight.fullname" -}}
{{- default .Release.Name .Values.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "insight.labels" -}}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version }}
app.kubernetes.io/name: {{ .Chart.Name }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: insight
{{- end -}}

{{/*
==============================================================================
 SERVICE RESOLUTION HELPERS
==============================================================================
Contract: each helper returns either the internal DNS (if the subchart is
enabled) or the value from external.* (if enabled=false). Every field is
required — no silent defaults. Missing values fail at helm template time.

`enabled: true` means "Insight provides and manages this component".
`enabled: false` means "the Constructor Platform (or another operator)
provides it externally; Insight only consumes it". Required for platform
integration where infra is shared across products.
==============================================================================
*/}}

{{/* ---------- ClickHouse ---------- */}}
{{- define "insight.clickhouse.host" -}}
{{- if .Values.clickhouse.enabled -}}
{{- printf "%s-clickhouse" .Release.Name -}}
{{- else -}}
{{- required "clickhouse.enabled=false requires clickhouse.external.host" .Values.clickhouse.external.host -}}
{{- end -}}
{{- end -}}

{{- define "insight.clickhouse.port" -}}
{{- if .Values.clickhouse.enabled -}}
8123
{{- else -}}
{{- required "clickhouse.enabled=false requires clickhouse.external.port" .Values.clickhouse.external.port -}}
{{- end -}}
{{- end -}}

{{- /*
     fqdn = dial-able host. For the internal subchart we build a full
     cluster-DNS name; for external mode we return the user-provided host
     verbatim. Don't blindly append `.<ns>.svc.cluster.local` in external
     mode — that would mangle e.g. `clickhouse.example.com` into
     `clickhouse.example.com.insight.svc.cluster.local`.
*/ -}}
{{- define "insight.clickhouse.fqdn" -}}
{{- if .Values.clickhouse.enabled -}}
{{ include "insight.clickhouse.host" . }}.{{ .Release.Namespace }}.svc.cluster.local
{{- else -}}
{{ include "insight.clickhouse.host" . }}
{{- end -}}
{{- end -}}

{{- define "insight.clickhouse.url" -}}
http://{{ include "insight.clickhouse.host" . }}:{{ include "insight.clickhouse.port" . }}
{{- end -}}

{{- define "insight.clickhouse.database" -}}
{{- required "clickhouse.database is required" .Values.clickhouse.database -}}
{{- end -}}

{{/* ---------- MariaDB ---------- */}}
{{- define "insight.mariadb.host" -}}
{{- if .Values.mariadb.enabled -}}
{{- printf "%s-mariadb" .Release.Name -}}
{{- else -}}
{{- required "mariadb.enabled=false requires mariadb.external.host" .Values.mariadb.external.host -}}
{{- end -}}
{{- end -}}

{{- define "insight.mariadb.port" -}}
{{- if .Values.mariadb.enabled -}}
3306
{{- else -}}
{{- required "mariadb.enabled=false requires mariadb.external.port" .Values.mariadb.external.port -}}
{{- end -}}
{{- end -}}

{{- define "insight.mariadb.database" -}}
{{- if .Values.mariadb.enabled -}}
{{- required "mariadb.auth.database is required" .Values.mariadb.auth.database -}}
{{- else -}}
{{- required "mariadb.external.database is required" .Values.mariadb.external.database -}}
{{- end -}}
{{- end -}}

{{/* ---------- Redis ---------- */}}
{{- define "insight.redis.host" -}}
{{- if .Values.redis.enabled -}}
{{- printf "%s-redis-master" .Release.Name -}}
{{- else -}}
{{- required "redis.enabled=false requires redis.external.host" .Values.redis.external.host -}}
{{- end -}}
{{- end -}}

{{- define "insight.redis.port" -}}
{{- if .Values.redis.enabled -}}
6379
{{- else -}}
{{- required "redis.enabled=false requires redis.external.port" .Values.redis.external.port -}}
{{- end -}}
{{- end -}}

{{- define "insight.redis.url" -}}
redis://{{ include "insight.redis.host" . }}:{{ include "insight.redis.port" . }}
{{- end -}}

{{/*
==============================================================================
 AIRBYTE (separate release, SAME namespace)
==============================================================================
Airbyte is installed as its own Helm release into the same namespace as the
umbrella (single-namespace deployment model). The DNS is therefore:

  {airbyte-release-name}-airbyte-server-svc.{release-namespace}.svc.cluster.local:8001

If `airbyte.apiUrl` is set explicitly in values, that value wins — useful
for Constructor Platform integration where the platform provides Airbyte
externally.
==============================================================================
*/}}
{{- define "insight.airbyte.url" -}}
{{- if .Values.airbyte.apiUrl -}}
{{- .Values.airbyte.apiUrl -}}
{{- else -}}
http://{{ .Values.airbyte.releaseName }}-airbyte-server-svc.{{ .Release.Namespace }}.svc.cluster.local:8001
{{- end -}}
{{- end -}}

{{/* ---------- Redpanda ---------- */}}
{{- define "insight.redpanda.brokers" -}}
{{- if .Values.redpanda.enabled -}}
{{- printf "%s-redpanda:9092" .Release.Name -}}
{{- else -}}
{{- required "redpanda.enabled=false requires redpanda.external.brokers" .Values.redpanda.external.brokers -}}
{{- end -}}
{{- end -}}

{{/*
==============================================================================
 APP SERVICE HOSTS
==============================================================================
App services are MANDATORY components of Insight — the gateway is the only
entrance to the cluster internals, the rest of the services sit behind it.
No enabled-flag here: the umbrella always deploys all four.

These helpers stay for DRY so ingestion templates and any future sidecar
can reference the services via the same helper pattern.
==============================================================================
*/}}
{{- define "insight.apiGateway.host"   -}}{{- printf "%s-api-gateway"          .Release.Name -}}{{- end -}}
{{- define "insight.analyticsApi.host" -}}{{- printf "%s-analytics-api"        .Release.Name -}}{{- end -}}
{{- define "insight.identity.host"     -}}{{- printf "%s-identity-resolution" .Release.Name -}}{{- end -}}
{{- define "insight.frontend.host"     -}}{{- printf "%s-frontend"             .Release.Name -}}{{- end -}}

{{/*
==============================================================================
 VALIDATORS
==============================================================================
Fail-fast checks that run at helm template / install time.
Invoked from NOTES.txt so they fire on every install.
==============================================================================
*/}}
{{- define "insight.validate" -}}
  {{- /* OIDC is required when auth is not disabled. Either supply a pre-created
         Secret, or set ALL three inline fields (issuer, clientId, redirectUri).
         Checking only one of them lets typos slip through and fails at runtime. */ -}}
  {{- if not .Values.apiGateway.authDisabled -}}
    {{- if not .Values.apiGateway.oidc.existingSecret -}}
      {{- if or (not .Values.apiGateway.oidc.issuer)
                (not .Values.apiGateway.oidc.clientId)
                (not .Values.apiGateway.oidc.redirectUri) -}}
        {{- fail "apiGateway.oidc: when existingSecret is empty and authDisabled=false, issuer AND clientId AND redirectUri are ALL required" -}}
      {{- end -}}
    {{- end -}}
  {{- end -}}

  {{- /* External-mode contracts. Each dep (CH/MariaDB/Redis/Redpanda) must
         provide host, port, and credential source — typos in any of these
         would otherwise only surface at runtime. */ -}}

  {{- /* ClickHouse */ -}}
  {{- if not .Values.clickhouse.enabled -}}
    {{- if not .Values.clickhouse.external.host -}}
      {{- fail "clickhouse.enabled=false requires clickhouse.external.host" -}}
    {{- end -}}
    {{- if not .Values.clickhouse.external.port -}}
      {{- fail "clickhouse.enabled=false requires clickhouse.external.port" -}}
    {{- end -}}
    {{- if not .Values.clickhouse.external.credentialsSecret.name -}}
      {{- fail "clickhouse.enabled=false requires clickhouse.external.credentialsSecret.name" -}}
    {{- end -}}
  {{- end -}}

  {{- /* MariaDB */ -}}
  {{- if not .Values.mariadb.enabled -}}
    {{- if not .Values.mariadb.external.host -}}
      {{- fail "mariadb.enabled=false requires mariadb.external.host" -}}
    {{- end -}}
    {{- if not .Values.mariadb.external.port -}}
      {{- fail "mariadb.enabled=false requires mariadb.external.port" -}}
    {{- end -}}
    {{- if not .Values.mariadb.external.database -}}
      {{- fail "mariadb.enabled=false requires mariadb.external.database" -}}
    {{- end -}}
    {{- if not .Values.mariadb.external.credentialsSecret.name -}}
      {{- fail "mariadb.enabled=false requires mariadb.external.credentialsSecret.name" -}}
    {{- end -}}
  {{- end -}}

  {{- /* Redis — passwordSecret required only if auth is on for the external instance */ -}}
  {{- if not .Values.redis.enabled -}}
    {{- if not .Values.redis.external.host -}}
      {{- fail "redis.enabled=false requires redis.external.host" -}}
    {{- end -}}
    {{- if not .Values.redis.external.port -}}
      {{- fail "redis.enabled=false requires redis.external.port" -}}
    {{- end -}}
  {{- end -}}

  {{- /* Redpanda — SASL credentials required only if external instance uses SASL */ -}}
  {{- if not .Values.redpanda.enabled -}}
    {{- if not .Values.redpanda.external.brokers -}}
      {{- fail "redpanda.enabled=false requires redpanda.external.brokers" -}}
    {{- end -}}
    {{- if .Values.redpanda.external.sasl.enabled -}}
      {{- if not .Values.redpanda.external.sasl.credentialsSecret.name -}}
        {{- fail "redpanda.external.sasl.enabled=true requires redpanda.external.sasl.credentialsSecret.name" -}}
      {{- end -}}
    {{- end -}}
  {{- end -}}

  {{- /* Bundled-infra credentials — when the subchart is installed by the
         umbrella, it needs a password. Empty defaults in canonical values
         (see #4 in the review) prevent accidental `changeme` in prod. */ -}}
  {{- if .Values.clickhouse.enabled -}}
    {{- if not .Values.clickhouse.auth.password -}}
      {{- fail "clickhouse.enabled=true requires clickhouse.auth.password (use -f deploy/values-dev.yaml for eval defaults)" -}}
    {{- end -}}
  {{- end -}}
  {{- if .Values.mariadb.enabled -}}
    {{- if not .Values.mariadb.auth.password -}}
      {{- fail "mariadb.enabled=true requires mariadb.auth.password (use -f deploy/values-dev.yaml for eval defaults)" -}}
    {{- end -}}
    {{- if not .Values.mariadb.auth.rootPassword -}}
      {{- fail "mariadb.enabled=true requires mariadb.auth.rootPassword" -}}
    {{- end -}}
  {{- end -}}
{{- end -}}
