{{- define "sftpgo.labels" -}}
app.kubernetes.io/name: sftpgo
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version }}
{{- end }}
{{- define "sftpgo.selector" -}}
app.kubernetes.io/name: sftpgo
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}
{{- define "sftpgo.securite" -}}
allowPrivilegeEscalation: false
readOnlyRootFilesystem: true
capabilities:
  drop: ["ALL"]
{{- end }}
