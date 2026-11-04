{{- define "api-gateway.labels" -}}
app.kubernetes.io/part-of: api-gateway
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end -}}

{{/* A path parameter that must be a UUID. */}}
{{- define "api-gateway.uuid" -}}[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}{{- end -}}

{{/* Every channel call must say which customer it is for (the BFF's customerKey, an HMAC). */}}
{{- define "api-gateway.customerKeyMatch" -}}
headers:
  - { type: RegularExpression, name: x-customer-key, value: "^[A-Za-z0-9_-]{16,128}$" }
{{- end -}}
