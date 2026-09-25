{{/*
  Names and labels. Nothing here delegates to a library: these are the three
  helpers the chart needs, written out.
*/}}

{{- define "nilchela.name" -}}
nilchela
{{- end -}}

{{- define "nilchela.fullname" -}}
{{- if contains (include "nilchela.name" .) .Release.Name -}}
{{- .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- printf "%s-%s" .Release.Name (include "nilchela.name" .) | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}

{{- define "nilchela.selectorLabels" -}}
app.kubernetes.io/name: {{ include "nilchela.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{- define "nilchela.labels" -}}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" }}
{{ include "nilchela.selectorLabels" . }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end -}}

{{- define "nilchela.image" -}}
{{- printf "%s:%s" .Values.image.repository (.Values.image.tag | default .Chart.AppVersion) -}}
{{- end -}}

{{- define "nilchela.serviceEnabled" -}}
{{- .Values.gateway.service.enabled | default true -}}
{{- end -}}
