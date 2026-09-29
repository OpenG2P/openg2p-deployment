{{/*
Return the proper  image name
*/}}
{{- define "idgenerator.image" -}}
{{ include "common.images.image" (dict "imageRoot" .Values.image "global" .Values.global) }}
{{- end -}}

{{/*
Return the proper image name (for the init container volume-permissions image)
*/}}
{{- define "idgenerator.volumePermissions.image" -}}
{{- include "common.images.image" ( dict "imageRoot" .Values.volumePermissions.image "global" .Values.global ) -}}
{{- end -}}

{{/*
Return the config server image name
*/}}
{{- define "idgenerator.config-server.image" -}}
{{ include "common.images.image" (dict "imageRoot" .Values.springCloudConfig.image "global" .Values.global) }}
{{- end -}}

{{/*
Return the proper Docker Image Registry Secret Names
*/}}
{{- define "idgenerator.imagePullSecrets" -}}
{{- include "common.images.pullSecrets" (dict "images" (list .Values.image .Values.springCloudConfig.image .Values.volumePermissions.image) "global" .Values.global) -}}
{{- end -}}

{{/*
Create the name of the service account to use
*/}}
{{- define "idgenerator.serviceAccountName" -}}
{{- if .Values.serviceAccount.create -}}
    {{ default (printf "%s" (include "common.names.fullname" .)) .Values.serviceAccount.name }}
{{- else -}}
    {{ default "default" .Values.serviceAccount.name }}
{{- end -}}
{{- end -}}

{{/*
Return podAnnotations
*/}}
{{- define "idgenerator.podAnnotations" -}}
{{- if .Values.podAnnotations }}
{{ include "common.tplvalues.render" (dict "value" .Values.podAnnotations "context" $) }}
{{- end }}
{{- if and .Values.metrics.enabled .Values.metrics.podAnnotations }}
{{ include "common.tplvalues.render" (dict "value" .Values.metrics.podAnnotations "context" $) }}
{{- end }}
{{- end -}}

{{/*
Render Env values section
*/}}
{{- define "idgenerator.baseEnvVars" -}}
{{- $context := .context -}}
{{- range $k, $v := .envVars }}
- name: {{ $k }}
{{- if or (kindIs "int64" $v) (kindIs "float64" $v) (kindIs "bool" $v) }}
  value: {{ $v | quote }}
{{- else if kindIs "string" $v }}
  value: {{ include "common.tplvalues.render" ( dict "value" $v "context" $context ) | squote }}
{{- else }}
  valueFrom: {{- include "common.tplvalues.render" ( dict "value" $v "context" $context ) | nindent 4}}
{{- end }}
{{- end }}
{{- end -}}

{{- define "idgenerator.envVars" -}}
{{- $envVars := merge (.Values.springCloudConfig.enabled | ternary (deepCopy .Values.springCloudConfigEnvVars) dict) (deepCopy .Values.coreEnvVars) (deepCopy .Values.coreEnvVarsFrom) (.Values.springCloudConfig.enabled | ternary dict (merge (deepCopy .Values.envVars) (deepCopy .Values.envVarsFrom))) -}}
{{- include "idgenerator.baseEnvVars" (dict "envVars" $envVars "context" $) }}
{{- end -}}

{{- define "idgenerator.postgresInit.envVars" -}}
{{- $envVars := merge (deepCopy .Values.postgresInit.envVars) (deepCopy .Values.postgresInit.envVarsFrom) -}}
{{- include "idgenerator.baseEnvVars" (dict "envVars" $envVars "context" $) }}
{{- end -}}

{{- define "idgenerator.command" -}}
{{- include "idgenerator.commandBase" (dict "command" .Values.command "args" .Values.args "startUpCommand" .Values.startUpCommand "context" $) }}
{{- end -}}

{{- define "idgenerator.postgresInit.command" -}}
{{- include "idgenerator.commandBase" (dict "command" .Values.postgresInit.command "args" .Values.postgresInit.args "startUpCommand" .Values.postgresInit.startUpCommand "context" $) }}
{{- end -}}

{{- define "idgenerator.config-server.envVars" -}}
{{- $overridesEnvVars := dict -}}
{{- if .Values.springCloudConfig.enabled -}}
{{- range $k, $v := (merge (deepCopy .Values.envVars) (deepCopy .Values.envVarsFrom)) -}}
{{- $_ := set $overridesEnvVars (printf "spring_cloud_config_server_overrides_%s" $k) $v -}}
{{- end -}}
{{- end -}}
{{- $envVars := merge $overridesEnvVars (deepCopy .Values.springCloudConfig.envVars) (deepCopy .Values.springCloudConfig.envVarsFrom) -}}
{{- include "idgenerator.baseEnvVars" (dict "envVars" $envVars "context" $) }}
{{- end -}}

{{/*
Return command
*/}}
{{- define "idgenerator.commandBase" -}}
{{- if or .command .args }}
{{- if .command }}
command: {{- include "common.tplvalues.render" (dict "value" .command "context" .context) }}
{{- end }}
{{- if .args }}
args: {{- include "common.tplvalues.render" (dict "value" .args "context" .context) }}
{{- end }}
{{- else if .startUpCommand }}
command: ["/startup.sh"]
args: []
{{- end }}
{{- end -}}
