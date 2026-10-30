{{- define "pipeline-app.name" -}}
{{- .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "pipeline-app.labels" -}}
app.kubernetes.io/name: {{ include "pipeline-app.name" . }}
app.kubernetes.io/part-of: event-pipeline
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/version: {{ .Values.image.tag | default .Chart.AppVersion | trunc 63 | quote }}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end -}}

{{- define "pipeline-app.selectorLabels" -}}
app.kubernetes.io/name: {{ include "pipeline-app.name" . }}
app.kubernetes.io/part-of: event-pipeline
{{- end -}}
