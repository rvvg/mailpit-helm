{{/* Chart name */}}
{{- define "mailpit.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/* Fully qualified app name */}}
{{- define "mailpit.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else if contains (include "mailpit.name" .) .Release.Name }}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name (include "mailpit.name" .) | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}

{{- define "mailpit.selectorLabels" -}}
app.kubernetes.io/name: {{ include "mailpit.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{- define "mailpit.labels" -}}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" }}
{{ include "mailpit.selectorLabels" . }}
app.kubernetes.io/version: {{ include "mailpit.imageTag" . | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- with .Values.commonLabels }}
{{ toYaml . }}
{{- end }}
{{- end }}

{{- define "mailpit.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "mailpit.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{- define "mailpit.imageTag" -}}
{{- .Values.image.tag | default .Chart.AppVersion }}
{{- end }}

{{- define "mailpit.image" -}}
{{- $repo := .Values.image.repository }}
{{- with .Values.image.registry }}{{ $repo = printf "%s/%s" . $repo }}{{ end }}
{{- if .Values.image.digest }}
{{- printf "%s@%s" $repo .Values.image.digest }}
{{- else }}
{{- printf "%s:%s" $repo (include "mailpit.imageTag" .) }}
{{- end }}
{{- end }}

{{/* Webroot normalised to "/path/" */}}
{{- define "mailpit.webroot" -}}
{{- $r := .Values.mailpit.webroot | default "/" -}}
{{- if not (hasPrefix "/" $r) }}{{ $r = printf "/%s" $r }}{{ end -}}
{{- if not (hasSuffix "/" $r) }}{{ $r = printf "%s/" $r }}{{ end -}}
{{- $r -}}
{{- end }}

{{/* Name of the chart-managed secret with htpasswd files */}}
{{- define "mailpit.authSecretName" -}}
{{- printf "%s-auth" (include "mailpit.fullname" .) }}
{{- end }}

{{/* True when the chart must render its own auth secret */}}
{{- define "mailpit.createAuthSecret" -}}
{{- $m := .Values.mailpit -}}
{{- if or (and $m.ui.auth.enabled (not $m.ui.auth.existingSecret)) (and $m.smtp.auth.enabled (not $m.smtp.auth.existingSecret)) (and $m.sendApi.auth.enabled (not $m.sendApi.auth.existingSecret)) -}}
true
{{- end -}}
{{- end }}

{{- define "mailpit.smtpTlsSecretName" -}}
{{- .Values.mailpit.smtp.tls.secretName | default (printf "%s-smtp-tls" (include "mailpit.fullname" .)) }}
{{- end }}

{{/* In-cluster DNS names of the main service */}}
{{- define "mailpit.serviceHosts" -}}
{{- $svc := include "mailpit.fullname" . -}}
{{- list $svc (printf "%s.%s" $svc .Release.Namespace) (printf "%s.%s.svc" $svc .Release.Namespace) (printf "%s.%s.svc.cluster.local" $svc .Release.Namespace) | toJson -}}
{{- end }}

{{/* MP_ALLOWED_HOSTS: user list + ingress/route hosts + service names + localhost */}}
{{- define "mailpit.allowedHosts" -}}
{{- $hosts := list -}}
{{- if .Values.mailpit.ui.allowedHosts -}}
{{- $hosts = concat .Values.mailpit.ui.allowedHosts (include "mailpit.serviceHosts" . | fromJsonArray) (list "localhost" "127.0.0.1") -}}
{{- if .Values.ingress.enabled }}{{ range .Values.ingress.hosts }}{{ $hosts = append $hosts .host }}{{ end }}{{ end -}}
{{- if .Values.httpRoute.enabled }}{{ $hosts = concat $hosts .Values.httpRoute.hostnames }}{{ end -}}
{{- end -}}
{{- $hosts | uniq | join "," -}}
{{- end }}

{{/* Probe spec */}}
{{- define "mailpit.probe" -}}
{{- $p := omit .probe "enabled" -}}
httpGet:
  path: {{ include "mailpit.webroot" .ctx }}{{ .path }}
  port: http
  scheme: {{ .ctx.Values.mailpit.ui.tls.enabled | ternary "HTTPS" "HTTP" }}
  {{- if include "mailpit.allowedHosts" .ctx }}
  httpHeaders:
    - name: Host
      value: localhost
  {{- end }}
{{- with $p }}
{{ toYaml . }}
{{- end }}
{{- end }}

{{/* Fail early on contradictory settings */}}
{{- define "mailpit.validate" -}}
{{- $m := .Values.mailpit -}}
{{- if and $m.sendApi.auth.enabled $m.sendApi.auth.acceptAny }}
{{- fail "mailpit.sendApi.auth.enabled and mailpit.sendApi.auth.acceptAny are mutually exclusive" }}
{{- end }}
{{- if and $m.smtp.tls.requireTLS $m.smtp.tls.requireStartTLS }}
{{- fail "mailpit.smtp.tls.requireTLS and requireStartTLS are mutually exclusive" }}
{{- end }}
{{- if and (or $m.smtp.tls.requireTLS $m.smtp.tls.requireStartTLS) (not $m.smtp.tls.enabled) }}
{{- fail "mailpit.smtp.tls.requireTLS/requireStartTLS need mailpit.smtp.tls.enabled" }}
{{- end }}
{{- $tlsSources := 0 }}
{{- if $m.smtp.tls.secretName }}{{ $tlsSources = add1 $tlsSources }}{{ end }}
{{- if $m.smtp.tls.certManager.enabled }}{{ $tlsSources = add1 $tlsSources }}{{ end }}
{{- if $m.smtp.tls.selfSigned }}{{ $tlsSources = add1 $tlsSources }}{{ end }}
{{- if and $m.smtp.tls.enabled (eq $tlsSources 0) }}
{{- fail "mailpit.smtp.tls.enabled needs one of secretName, certManager.enabled or selfSigned" }}
{{- end }}
{{- if and $m.smtp.tls.selfSigned (or $m.smtp.tls.secretName $m.smtp.tls.certManager.enabled) }}
{{- fail "mailpit.smtp.tls.selfSigned cannot be combined with secretName or certManager" }}
{{- end }}
{{- if and $m.ui.tls.enabled (not $m.ui.tls.secretName) }}
{{- fail "mailpit.ui.tls.enabled needs mailpit.ui.tls.secretName" }}
{{- end }}
{{- if and $m.metrics.serviceMonitor.enabled (not $m.metrics.enabled) }}
{{- fail "mailpit.metrics.serviceMonitor.enabled needs mailpit.metrics.enabled" }}
{{- end }}
{{- if and .Values.ingress.oauth2Proxy.enabled (not (hasPrefix "https://" .Values.ingress.oauth2Proxy.url)) }}
{{- fail "ingress.oauth2Proxy.url must start with https://" }}
{{- end }}
{{- end }}

{{/* Labels for auxiliary pods: deliberately without selector labels so they are
     neither Service endpoints nor selected by the NetworkPolicy */}}
{{- define "mailpit.auxLabels" -}}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" }}
app.kubernetes.io/part-of: {{ include "mailpit.name" . }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}
