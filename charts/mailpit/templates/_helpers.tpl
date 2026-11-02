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

{{/* Name of the chart-managed secret with relay/forward/tag config files */}}
{{- define "mailpit.configSecretName" -}}
{{- printf "%s-config" (include "mailpit.fullname" .) }}
{{- end }}

{{/* Basic-auth consumers as a JSON list of {name, file, enabled, htpasswd, existingSecret, existingSecretKey};
     the file name is the mount path below /secrets */}}
{{- define "mailpit.authKinds" -}}
{{- $m := .Values.mailpit -}}
{{- $kinds := list
  (merge (dict "name" "ui" "enabled" $m.ui.auth.enabled) $m.ui.auth)
  (merge (dict "name" "smtp" "enabled" $m.smtp.auth.enabled) $m.smtp.auth)
  (merge (dict "name" "sendApi" "enabled" $m.sendApi.auth.enabled) $m.sendApi.auth)
  (merge (dict "name" "pop3" "enabled" $m.pop3.enabled) $m.pop3.auth) -}}
{{- $out := list -}}
{{- range $kinds }}{{ $out = append $out (set (pick . "name" "enabled" "htpasswd" "existingSecret" "existingSecretKey") "file" (printf "%s.htpasswd" .name)) }}{{ end -}}
{{- toJson $out -}}
{{- end }}

{{/* Config files as a JSON list of {file, enabled, config, existingSecret, existingSecretKey} */}}
{{- define "mailpit.configFiles" -}}
{{- $m := .Values.mailpit -}}
{{- toJson (list
  (dict "file" "relay.yaml" "enabled" (ne $m.smtp.relay.mode "disabled") "config" $m.smtp.relay.config "existingSecret" $m.smtp.relay.existingSecret "existingSecretKey" $m.smtp.relay.existingSecretKey)
  (dict "file" "forward.yaml" "enabled" $m.smtp.forward.enabled "config" $m.smtp.forward.config "existingSecret" $m.smtp.forward.existingSecret "existingSecretKey" $m.smtp.forward.existingSecretKey)
  (dict "file" "tags.yaml" "enabled" (not (empty $m.tags.config)) "config" $m.tags.config "existingSecret" "" "existingSecretKey" "")) -}}
{{- end }}

{{/* Projected volume sources for enabled items of an authKinds/configFiles list.
     Args: dict "items" <list> "chartSecret" <name> */}}
{{- define "mailpit.projectedSources" -}}
{{- $out := list -}}
{{- range .items }}
{{- if .enabled }}
{{- $name := .existingSecret | default $.chartSecret }}
{{- $key := ternary .existingSecretKey .file (not (empty .existingSecret)) }}
{{- $out = append $out (dict "secret" (dict "name" $name "items" (list (dict "key" $key "path" .file)))) }}
{{- end }}
{{- end }}
{{- toJson $out -}}
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
{{- if and (ne $m.smtp.relay.mode "disabled") (empty $m.smtp.relay.config) (not $m.smtp.relay.existingSecret) }}
{{- fail "mailpit.smtp.relay needs config or existingSecret when mode is not disabled" }}
{{- end }}
{{- if and (eq $m.smtp.relay.mode "matching") (not $m.smtp.relay.matching) }}
{{- fail "mailpit.smtp.relay.matching is required when mode is matching" }}
{{- end }}
{{- if and $m.smtp.forward.enabled (empty $m.smtp.forward.config) (not $m.smtp.forward.existingSecret) }}
{{- fail "mailpit.smtp.forward needs config or existingSecret when enabled" }}
{{- end }}
{{- if and $m.pop3.enabled (not $m.pop3.auth.htpasswd) (not $m.pop3.auth.existingSecret) }}
{{- fail "mailpit.pop3 needs auth.htpasswd or auth.existingSecret - Mailpit requires POP3 authentication" }}
{{- end }}
{{- if and $m.pop3.enabled $m.pop3.tls.enabled (not $m.pop3.tls.secretName) }}
{{- fail "mailpit.pop3.tls.enabled needs mailpit.pop3.tls.secretName" }}
{{- end }}
{{- if and $m.spamCheck.engine (not $m.spamCheck.address) }}
{{- fail "mailpit.spamCheck.address is required when mailpit.spamCheck.engine is set" }}
{{- end }}
{{- if and $m.webhook.url $m.webhook.existingSecret }}
{{- fail "mailpit.webhook.url and mailpit.webhook.existingSecret are mutually exclusive" }}
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

{{/* Render [[NAME, value], ...] as container env. Rules: nil, "" and false are
     skipped; true becomes "true"; numbers (also 0) and strings are quoted. */}}
{{- define "mailpit.envTable" -}}
{{- range . }}
{{- $v := index . 1 }}
{{- if kindIs "bool" $v }}
{{- if $v }}
- name: {{ index . 0 }}
  value: "true"
{{- end }}
{{- else if and (not (kindIs "invalid" $v)) (ne (toString $v) "") }}
- name: {{ index . 0 }}
  value: {{ $v | toString | quote }}
{{- end }}
{{- end }}
{{- end }}
