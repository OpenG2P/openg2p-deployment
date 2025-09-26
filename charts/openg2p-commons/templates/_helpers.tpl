{{/*
Render Env values section
*/}}
{{- define "openg2pCommon.baseEnvVars" -}}
{{- $context := .context -}}
{{- range $k, $v := .envVars }}
{{- if or (kindIs "int64" $v) (kindIs "float64" $v) (kindIs "bool" $v) }}
- name: {{ $k }}
  value: {{ $v | quote }}
{{- else if kindIs "string" $v }}
- name: {{ $k }}
  value: {{ include "common.tplvalues.render" ( dict "value" $v "context" $context ) | squote }}
{{- else }}
{{- $vEnabled := "true" }}
{{- if hasKey $v "enabled" }}
{{- $vEnabled = kindIs "bool" $v.enabled | ternary ($v.enabled | squote) (include "common.tplvalues.render" (dict "value" $v.enabled "context" $context)) }}
{{- $v = omit $v "enabled" }}
{{- end }}
{{- if eq $vEnabled "true" }}
- name: {{ $k }}
  valueFrom: {{- include "common.tplvalues.render" ( dict "value" $v "context" $context ) | nindent 4}}
{{- end }}
{{- end }}
{{- end }}
{{- end -}}

{{- define "openg2pCommon.kafka-ui.envVars" -}}
{{- $envVars := merge (deepCopy .Values.kafkaUi.envVars) (deepCopy .Values.kafkaUi.envVarsFrom) -}}
{{- include "openg2pCommon.baseEnvVars" (dict "envVars" $envVars "context" $) }}
{{- end -}}
