{{- define "insight-api-gateway.fullname" -}}
{{ .Release.Name }}-api-gateway
{{- end }}

{{- define "insight-api-gateway.labels" -}}
app.kubernetes.io/name: api-gateway
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{- define "insight-api-gateway.selectorLabels" -}}
app.kubernetes.io/name: api-gateway
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}
