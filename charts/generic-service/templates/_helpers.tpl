{{/* 服务名：nameOverride > service > Chart.Name */}}
{{- define "generic-service.name" -}}
{{- .Values.nameOverride | default .Values.service | default .Chart.Name | trunc 63 | trimSuffix "-" -}}
{{- end }}

{{- define "generic-service.fullname" -}}
{{- include "generic-service.name" . -}}
{{- end }}

{{/* 通用标签（含环境，便于按 env 筛选） */}}
{{- define "generic-service.labels" -}}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version }}
app.kubernetes.io/name: {{ include "generic-service.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/component: backend
env: {{ .Values.env | default "unknown" | quote }}
{{- end }}

{{- define "generic-service.selectorLabels" -}}
app.kubernetes.io/name: {{ include "generic-service.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/* 必填校验：任一渲染入口先执行，缺失直接 fail（不回退默认值，防静默错误） */}}
{{- define "generic-service.validations" -}}
{{- if not .Values.service }}{{ fail "values 缺少必填字段: service（deploy 仓库 envs 文件顶部）" }}{{ end -}}
{{- if not .Values.env }}{{ fail "values 缺少必填字段: env（deploy 仓库 envs 文件顶部）" }}{{ end -}}
{{- if not .Values.image.repository }}{{ fail "values 缺少必填字段: image.repository" }}{{ end -}}
{{- if not .Values.image.tag }}{{ fail "values 缺少必填字段: image.tag（不回退 appVersion，防静默部署旧版本）" }}{{ end -}}
{{- if and .Values.ingress.enabled (not .Values.ingress.host) }}{{ fail "ingress.enabled 时 ingress.host 必填" }}{{ end -}}
{{- end }}

{{/* imageCredentials（仅 dev 临时验证用）的 dockerconfigjson */}}
{{- define "generic-service.imagePullSecret" -}}
{{- with .Values.imageCredentials -}}
{{- $auth := printf "%s:%s" .username .password | b64enc -}}
{{- printf "{\"auths\":{\"%s\":{\"username\":\"%s\",\"password\":\"%s\",\"auth\":\"%s\"}}}" .registry .username .password $auth | b64enc -}}
{{- end -}}
{{- end }}
