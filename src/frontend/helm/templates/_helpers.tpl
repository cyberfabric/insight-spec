{{- define "insight-frontend.fullname" -}}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "insight-frontend.labels" -}}
app.kubernetes.io/name: insight-frontend
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{- define "insight-frontend.selectorLabels" -}}
app.kubernetes.io/name: insight-frontend
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}
