{{/*
Chart fullname — uses release name
*/}}
{{- define "mysql.fullname" -}}
{{- .Release.Name -}}
{{- end -}}

{{/*
Common labels
*/}}
{{- define "mysql.labels" -}}
app.kubernetes.io/name: mysql
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end -}}

{{/*
Selector labels
*/}}
{{- define "mysql.selectorLabels" -}}
app.kubernetes.io/name: mysql
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{/*
Secret name — either existing or generated
*/}}
{{- define "mysql.secretName" -}}
{{- if .Values.auth.existingSecret -}}
{{- .Values.auth.existingSecret -}}
{{- else -}}
{{- include "mysql.fullname" . -}}
{{- end -}}
{{- end -}}
