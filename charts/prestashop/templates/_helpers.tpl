{{/*
Expand the name of the chart.
*/}}
{{- define "prestashop.name" -}}
{{- .Chart.Name | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
*/}}
{{- define "prestashop.fullname" -}}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "prestashop.labels" -}}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version }}
app.kubernetes.io/name: {{ include "prestashop.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Selector labels - PrestaShop app
*/}}
{{- define "prestashop.selectorLabels" -}}
app.kubernetes.io/name: {{ include "prestashop.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/component: app
{{- end }}

{{/*
Selector labels - MariaDB
*/}}
{{- define "prestashop.mariadb.selectorLabels" -}}
app.kubernetes.io/name: {{ include "prestashop.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/component: mariadb
{{- end }}

{{/*
Secret name
*/}}
{{- define "prestashop.secretName" -}}
{{ include "prestashop.fullname" . }}-secret
{{- end }}

{{/*
MariaDB service name (used by PrestaShop to connect)
*/}}
{{- define "prestashop.mariadb.serviceName" -}}
{{ include "prestashop.fullname" . }}-mariadb
{{- end }}
