{{/*
Chart fullname — uses release name
*/}}
{{- define "postgresql.fullname" -}}
{{- .Release.Name -}}
{{- end -}}

{{/*
Common labels
*/}}
{{- define "postgresql.labels" -}}
app.kubernetes.io/name: postgresql
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end -}}

{{/*
Selector labels
*/}}
{{- define "postgresql.selectorLabels" -}}
app.kubernetes.io/name: postgresql
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{/*
Secret name — either existing or generated
*/}}
{{- define "postgresql.secretName" -}}
{{- if .Values.auth.existingSecret -}}
{{- .Values.auth.existingSecret -}}
{{- else -}}
{{- include "postgresql.fullname" . -}}
{{- end -}}
{{- end -}}
