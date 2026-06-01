{{- define "workspace.name" -}}
workspace
{{- end -}}

{{- define "workspace.fullname" -}}
ws-{{ .Values.projectId }}
{{- end -}}

{{- define "workspace.labels" -}}
app.kubernetes.io/name: {{ include "workspace.name" . }}
app.kubernetes.io/instance: {{ include "workspace.fullname" . }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
carbide.project-id: {{ .Values.projectId | quote }}
{{- end -}}

{{- define "workspace.selectorLabels" -}}
app.kubernetes.io/name: {{ include "workspace.name" . }}
app.kubernetes.io/instance: {{ include "workspace.fullname" . }}
{{- end -}}

{{- define "workspace.databaseName" -}}
{{- if .Values.postgres.databaseName -}}
{{ .Values.postgres.databaseName }}
{{- else -}}
carbide_workspace_{{ .Values.projectId }}
{{- end -}}
{{- end -}}

{{- define "workspace.testDatabaseName" -}}
{{ include "workspace.databaseName" . }}_test
{{- end -}}

{{- define "workspace.pathPrefix" -}}
{{ tpl .Values.ingress.pathPrefix . }}
{{- end -}}
