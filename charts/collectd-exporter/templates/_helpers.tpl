{{- define "collectd-exporter.labels" -}}
app.kubernetes.io/name: collectd-exporter
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version }}
{{- end }}
{{- define "collectd-exporter.selector" -}}
app.kubernetes.io/name: collectd-exporter
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}
