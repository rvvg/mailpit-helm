# Mailpit Helm Chart

[![Artifact Hub](https://img.shields.io/endpoint?url=https://artifacthub.io/badge/repository/mailpit-helm)](https://artifacthub.io/packages/search?repo=mailpit-helm)
[![Lint and Test](https://github.com/rvvg/mailpit-helm/actions/workflows/lint-test.yaml/badge.svg)](https://github.com/rvvg/mailpit-helm/actions/workflows/lint-test.yaml)
[![Release](https://img.shields.io/github/v/release/rvvg/mailpit-helm?filter=mailpit-*)](https://github.com/rvvg/mailpit-helm/releases)
[![License](https://img.shields.io/badge/license-Apache--2.0-blue.svg)](LICENSE)

A secure-by-default, dependency-free Helm chart for [Mailpit](https://mailpit.axllent.org) — the email & SMTP
testing tool with a modern web UI and REST API. Point your applications at Mailpit in dev, QA or staging
clusters and every outgoing email is captured instead of being delivered.

- **Hardened out of the box** — `restricted` Pod Security Standard, read-only root filesystem, non-root,
  no ServiceAccount token, no outbound version check.
- **Opt-in defence in depth** — NetworkPolicy with default-deny egress, basic auth for UI / SMTP / Send API,
  `Host` header allow-list against DNS rebinding, SMTP STARTTLS/TLS, oauth2-proxy SSO on ingress-nginx.
- **Operable** — Prometheus metrics on a dedicated port + ServiceMonitor, `helm test`, JSON-schema
  validated values, fail-fast checks for contradictory settings.
- **Zero dependencies** — no library sub-charts; the chart renders the same everywhere.

## Contents

- [Quick start](#quick-start)
- [How it compares](#how-it-compares)
- [Security](#security)
- [Configuration examples](#configuration-examples)
- [Using Mailpit from applications and tests](#using-mailpit-from-applications-and-tests)
- [Upgrading](#upgrading)
- [Parameters](#parameters)
- [Development](#development)

## Quick start

Requirements: Kubernetes 1.25+, Helm 3.8+.

```console
# OCI registry (recommended, signed with cosign)
helm install mailpit oci://ghcr.io/rvvg/charts/mailpit -n mailpit --create-namespace

# or the classic Helm repository
helm repo add mailpit-helm https://rvvg.github.io/mailpit-helm
helm install mailpit mailpit-helm/mailpit -n mailpit --create-namespace
```

```console
kubectl -n mailpit port-forward svc/mailpit 8025:8025   # web UI on http://localhost:8025
helm test mailpit -n mailpit                            # sends a message and checks the UI
```

Applications send mail to `mailpit.mailpit.svc:1025`.

> [!NOTE]
> Persistence is disabled by default: messages live in an `emptyDir` and disappear when the pod restarts.
> Set `persistence.enabled=true` to keep them on a PersistentVolume.

## How it compares

The most widely used alternative is the community chart [`jouve/mailpit`](https://github.com/jouve/charts)
(compared with version 0.39.0). Both charts are good choices; this one focuses on security controls and
cluster integration, that one ships first-class SMTP relay configuration.

| | **this chart** | jouve/mailpit 0.39.0 |
|---|:---:|:---:|
| External chart dependencies | **none** | `bitnami/common` library |
| Workload / storage | StatefulSet + volumeClaimTemplate, or existing PVC | Deployment + PVC (`Recreate`) |
| Restricted PSS security context | ✅ | ✅ |
| Dedicated ServiceAccount, token not mounted | ✅ | token not mounted |
| NetworkPolicy (ingress allow-list, default-deny egress) | ✅ | ❌ |
| `values.schema.json` validation | ✅ | ❌ |
| Fail-fast checks for contradictory settings | ✅ | ❌ |
| DNS-rebinding protection (`MP_ALLOWED_HOSTS`) wired to ingress hosts | ✅ | via env only |
| Outbound version check disabled by default | ✅ | ❌ |
| Basic auth: web UI / SMTP | ✅ / ✅ | ✅ / ✅ |
| Basic auth: Send API (`/api/v1/send`) | ✅ | via env only |
| oauth2-proxy SSO helper for ingress-nginx (groups / emails) | ✅ | ❌ |
| Prometheus metrics on a separate port + ServiceMonitor | ✅ | ❌ |
| `helm test` (web UI + SMTP round trip) | ✅ | ❌ |
| SMTP TLS: existing secret / cert-manager / self-signed at startup | ✅ / ✅ / ✅ | ✅ / ✅ / ✅ |
| Web UI TLS | ✅ | ✅ |
| Ingress / Gateway API HTTPRoute | ✅ / ✅ | ✅ / ✅ |
| Dedicated SMTP Service (e.g. internal LoadBalancer) | ✅ | ✅ (separate HTTP and SMTP services) |
| SMTP relay configuration | via `extraEnv`/`extraVolumes` (by design) | ✅ |
| Signed OCI artifact (cosign keyless) | ✅ | — |

**Why no first-class relay?** Mailpit in a shared cluster is a *mail sink*: the safest default is that a
captured message can never leave the cluster by accident. Relay and forwarding remain possible through
`extraEnv`, `extraVolumes` and `networkPolicy.egress.extra` for teams that need them and opt in
deliberately.

## Security

| Control | Default | How to change |
|---|---|---|
| Runs as UID/GID 1000, non-root, no privilege escalation, all capabilities dropped | on | `podSecurityContext`, `securityContext` |
| Read-only root filesystem (`/data` and `/tmp` are volumes) | on | `securityContext.readOnlyRootFilesystem` |
| `seccompProfile: RuntimeDefault` | on | `podSecurityContext.seccompProfile` |
| ServiceAccount token not mounted, service links disabled | on | `serviceAccount.automountServiceAccountToken` |
| No call to GitHub for new releases | on | `mailpit.disableVersionCheck` |
| No reverse DNS lookups of SMTP clients | on | `mailpit.smtp.disableRDNS` |
| NetworkPolicy: ingress only from the release namespace and listed peers, egress DNS only | off | `networkPolicy.enabled` |
| Web UI / API basic auth | off | `mailpit.ui.auth` |
| SSO via oauth2-proxy (ingress-nginx) | off | `ingress.oauth2Proxy` |
| `Host` header allow-list (DNS rebinding) | off | `mailpit.ui.allowedHosts` |
| SMTP authentication / STARTTLS / implicit TLS | off | `mailpit.smtp.auth`, `mailpit.smtp.tls` |
| Accepted recipients regex | off | `mailpit.smtp.allowedRecipients` |
| Remote CSS and fonts blocked in rendered mail | off | `mailpit.ui.blockRemoteCssAndFonts` |

Authentication defaults to *off* so that a fresh install works for every client, matching Mailpit's own
defaults. The chart prints a warning in `NOTES.txt` when the web UI is published through Ingress or
HTTPRoute without any authentication.

Secrets are never inlined into the pod spec: htpasswd files and TLS key pairs are mounted read-only
(`0440`) from Secrets, and you can reference existing Secrets (`existingSecret`) managed by
External Secrets, Sealed Secrets or Vault.

> [!IMPORTANT]
> NetworkPolicy needs a CNI that enforces it with the standard stateful semantics — Calico, Cilium,
> Antrea, AWS VPC CNI with network policies enabled, GKE Dataplane V2, etc. The `kindnet` CNI shipped with
> kind evaluates reply packets against egress rules and breaks connections when `networkPolicy.egress`
> is on; use Calico on kind or set `networkPolicy.egress.enabled=false` there.

## Configuration examples

Ready-to-use files live in [`examples/`](examples).

### Persistent, size-bounded mailbox

```yaml
persistence:
  enabled: true
  storageClassName: gp3
  size: 10Gi
mailpit:
  maxMessages: 20000   # prune oldest above this count
  maxAge: 14d          # and anything older than two weeks
```

### SSO with oauth2-proxy on ingress-nginx

Requires a running [oauth2-proxy](https://oauth2-proxy.github.io/oauth2-proxy/) whose cookie domain covers
the Mailpit host. Group membership is checked by oauth2-proxy on every request.

```yaml
ingress:
  enabled: true
  className: nginx
  annotations:
    cert-manager.io/cluster-issuer: letsencrypt
  hosts:
    - host: mailpit.example.com
  tls:
    - secretName: mailpit-tls
      hosts: [mailpit.example.com]
  oauth2Proxy:
    enabled: true
    url: https://oauth2-proxy.example.com
    allowedGroups: [mailpit-users]
mailpit:
  ui:
    allowedHosts: [mailpit.example.com]
```

> [!TIP]
> oauth2-proxy stores group membership in its session cookie. Run oauth2-proxy with `--cookie-refresh`
> (e.g. `1h`), otherwise users added to a group get `403` until they sign out or the cookie expires.

### Basic auth from an existing secret

```console
htpasswd -nbB admin 'S3cret!' > ui.htpasswd
kubectl -n mailpit create secret generic mailpit-ui-auth --from-file=ui.htpasswd
```

```yaml
mailpit:
  ui:
    auth:
      enabled: true
      existingSecret: mailpit-ui-auth
```

### Authenticated SMTP with STARTTLS from cert-manager

```yaml
mailpit:
  smtp:
    auth:
      enabled: true
      existingSecret: mailpit-smtp-auth     # key: smtp.htpasswd
    tls:
      enabled: true
      requireStartTLS: true
      certManager:
        enabled: true
        issuerRef:
          kind: ClusterIssuer
          name: internal-ca
```

### Locked-down network

```yaml
networkPolicy:
  enabled: true
  allowSameNamespace: false
  httpFrom:
    - namespaceSelector:
        matchLabels:
          kubernetes.io/metadata.name: ingress-nginx
  smtpFrom:
    - namespaceSelector:
        matchLabels:
          mailpit.example.com/smtp-client: "true"
  metricsFrom:
    - namespaceSelector:
        matchLabels:
          kubernetes.io/metadata.name: monitoring
  # egress stays DNS-only: no relay, webhooks, link checks or screenshots of external URLs
```

### Gateway API

```yaml
httpRoute:
  enabled: true
  parentRefs:
    - name: public
      namespace: gateway-system
  hostnames: [mailpit.example.com]
```

### Prometheus

```yaml
mailpit:
  metrics:
    enabled: true
    serviceMonitor:
      enabled: true
      labels:
        release: kube-prometheus-stack
```

Metrics are served on a separate port (`9090`) and Service (`<fullname>-metrics`), so they are never
reachable through the Ingress.

### Any other Mailpit option

Every [runtime option](https://mailpit.axllent.org/docs/configuration/runtime-options/) can be set with
`extraEnv`:

```yaml
extraEnv:
  - name: MP_WEBHOOK_URL
    value: https://hooks.example.com/mailpit
networkPolicy:
  egress:
    extra:
      - to:
          - ipBlock:
              cidr: 203.0.113.10/32
        ports:
          - port: 443
```

## Using Mailpit from applications and tests

| Purpose | Address |
|---|---|
| SMTP | `<release>-mailpit.<namespace>.svc:1025` (or `<release>.<namespace>.svc` when the release is named `mailpit`) |
| REST API | `http://<service>.<namespace>.svc:8025/api/v1/` — [API docs](https://mailpit.axllent.org/docs/api-v1/) |
| Clear the mailbox before a test run | `DELETE /api/v1/messages` |

In-cluster test runners should call the API through the Service, not the Ingress, so they are not
redirected to an SSO login page.

## Upgrading

- Mailpit stores messages in SQLite, so the chart always runs **one** replica.
- `volumeClaimTemplates` of a StatefulSet are immutable. To change `persistence.storageClassName`,
  `size` or `accessModes` after install, delete the StatefulSet with `--cascade=orphan`, adjust the PVC
  if required, and run `helm upgrade` again.
- PVCs are retained when the release is uninstalled (`persistence.retentionPolicy`). Delete them
  manually if you no longer need the messages.

## Parameters

<!-- PARAMS:START -->
| Key | Default | Description |
|-----|---------|-------------|
| `image.registry` | `"docker.io"` | Image registry |
| `image.repository` | `"axllent/mailpit"` | Image repository |
| `image.tag` | `""` | Image tag. Defaults to the chart `appVersion` |
| `image.digest` | `""` | Image digest (`sha256:...`). When set it takes precedence over the tag |
| `image.pullPolicy` | `"IfNotPresent"` | Image pull policy |
| `imagePullSecrets` | `[]` | Image pull secrets, e.g. `[{name: regcred}]` |
| `nameOverride` | `""` | Override the chart name |
| `fullnameOverride` | `""` | Override the full resource names |
| `commonLabels` | `{}` | Labels added to every resource |
| `serviceAccount.create` | `true` | Create a dedicated ServiceAccount (Mailpit never talks to the Kubernetes API) |
| `serviceAccount.name` | `""` | ServiceAccount name. Generated from the fullname when empty |
| `serviceAccount.annotations` | `{}` | ServiceAccount annotations |
| `serviceAccount.automountServiceAccountToken` | `false` | Mount the ServiceAccount token. Mailpit does not need it |
| `mailpit.label` | `""` | Instance label shown in the web UI, SMTP and POP3 greetings (`MP_LABEL`) |
| `mailpit.webroot` | `"/"` | Base path of the web UI and API (`MP_WEBROOT`), e.g. `/mailpit/` |
| `mailpit.timezone` | `"UTC"` | Container time zone (`TZ`) |
| `mailpit.maxMessages` | `500` | Max number of stored messages, oldest are pruned; `0` = unlimited (`MP_MAX_MESSAGES`) |
| `mailpit.maxAge` | `""` | Max message age, e.g. `36h` or `14d`; empty = unlimited (`MP_MAX_AGE`) |
| `mailpit.maxMessageSize` | `""` | Max accepted message size in MB; empty = Mailpit default 50 (`MP_MAX_MESSAGE_SIZE`) |
| `mailpit.disableVersionCheck` | `true` | Disable the periodic GitHub release check - no outbound calls (`MP_DISABLE_VERSION_CHECK`) |
| `mailpit.ui.auth.enabled` | `false` | Protect the web UI and API with HTTP basic auth (`MP_UI_AUTH_FILE`) |
| `mailpit.ui.auth.htpasswd` | `""` | htpasswd content (`user:bcrypt-hash` lines). Ignored when `existingSecret` is set |
| `mailpit.ui.auth.existingSecret` | `""` | Existing secret with the htpasswd file |
| `mailpit.ui.auth.existingSecretKey` | `"ui.htpasswd"` | Key in the secret that holds the htpasswd file |
| `mailpit.ui.tls.enabled` | `false` | Serve the web UI over HTTPS (`MP_UI_TLS_CERT`/`MP_UI_TLS_KEY`). Usually TLS terminates on the ingress instead |
| `mailpit.ui.tls.secretName` | `""` | Secret of type `kubernetes.io/tls` with `tls.crt`/`tls.key` |
| `mailpit.ui.allowedHosts` | `[]` | Allow-list of `Host` headers to mitigate DNS rebinding (`MP_ALLOWED_HOSTS`). Ingress/HTTPRoute hostnames, the in-cluster service names and `localhost` are added automatically when non-empty |
| `mailpit.ui.apiCors` | `""` | Hosts allowed to make cross-origin API requests (`MP_API_CORS`) |
| `mailpit.ui.blockRemoteCssAndFonts` | `false` | Block remote CSS and fonts in rendered messages via CSP (`MP_BLOCK_REMOTE_CSS_AND_FONTS`) |
| `mailpit.ui.hideDeleteAllButton` | `false` | Hide the "Delete all" button in the web UI (`MP_HIDE_DELETE_ALL_BUTTON`) |
| `mailpit.sendApi.auth.enabled` | `false` | Separate basic auth for the Send API `/api/v1/send` (`MP_SEND_API_AUTH_FILE`) |
| `mailpit.sendApi.auth.htpasswd` | `""` | htpasswd content. Ignored when `existingSecret` is set |
| `mailpit.sendApi.auth.existingSecret` | `""` | Existing secret with the htpasswd file |
| `mailpit.sendApi.auth.existingSecretKey` | `"send-api.htpasswd"` | Key in the secret that holds the htpasswd file |
| `mailpit.sendApi.auth.acceptAny` | `false` | Accept any credentials (or none) for the Send API (`MP_SEND_API_AUTH_ACCEPT_ANY`). Mutually exclusive with `enabled` |
| `mailpit.smtp.auth.enabled` | `false` | Require SMTP authentication from a password file (`MP_SMTP_AUTH_FILE`) |
| `mailpit.smtp.auth.htpasswd` | `""` | htpasswd content. Ignored when `existingSecret` is set |
| `mailpit.smtp.auth.existingSecret` | `""` | Existing secret with the htpasswd file |
| `mailpit.smtp.auth.existingSecretKey` | `"smtp.htpasswd"` | Key in the secret that holds the htpasswd file |
| `mailpit.smtp.auth.acceptAny` | `false` | Accept any SMTP credentials, or none (`MP_SMTP_AUTH_ACCEPT_ANY`). Handy for apps that always send AUTH |
| `mailpit.smtp.auth.allowInsecure` | `false` | Allow PLAIN/LOGIN auth without TLS (`MP_SMTP_AUTH_ALLOW_INSECURE`) |
| `mailpit.smtp.tls.enabled` | `false` | Enable STARTTLS on the SMTP server (`MP_SMTP_TLS_CERT`/`MP_SMTP_TLS_KEY`) |
| `mailpit.smtp.tls.secretName` | `""` | Secret of type `kubernetes.io/tls`. Defaults to `<fullname>-smtp-tls` when `certManager.enabled` |
| `mailpit.smtp.tls.selfSigned` | `false` | Let Mailpit generate a self-signed certificate at startup for the service DNS names (`sans:`). No secret needed |
| `mailpit.smtp.tls.requireStartTLS` | `false` | Reject commands until the client upgrades with STARTTLS (`MP_SMTP_REQUIRE_STARTTLS`) |
| `mailpit.smtp.tls.requireTLS` | `false` | Implicit TLS for every connection, disables STARTTLS (`MP_SMTP_REQUIRE_TLS`) |
| `mailpit.smtp.tls.certManager.enabled` | `false` | Issue the SMTP certificate with a cert-manager `Certificate` |
| `mailpit.smtp.tls.certManager.issuerRef` | `{}` | Issuer reference, e.g. `{kind: ClusterIssuer, name: internal-ca}` |
| `mailpit.smtp.tls.certManager.dnsNames` | `[]` | Extra DNS names (also used by `selfSigned`). In-cluster service names are always included |
| `mailpit.smtp.tls.certManager.duration` | `"2160h"` | Certificate duration |
| `mailpit.smtp.tls.certManager.renewBefore` | `"360h"` | Renew before expiry |
| `mailpit.smtp.allowedRecipients` | `""` | Regular expression recipients must match (`MP_SMTP_ALLOWED_RECIPIENTS`) |
| `mailpit.smtp.maxRecipients` | `""` | Max recipients per message; empty = Mailpit default 100 (`MP_SMTP_MAX_RECIPIENTS`) |
| `mailpit.smtp.disableRDNS` | `true` | Disable reverse DNS lookups of SMTP clients - useless for pod IPs (`MP_SMTP_DISABLE_RDNS`) |
| `mailpit.metrics.enabled` | `false` | Expose Prometheus metrics on a dedicated port (`MP_ENABLE_PROMETHEUS`), not reachable via ingress |
| `mailpit.metrics.port` | `9090` | Metrics port |
| `mailpit.metrics.serviceMonitor.enabled` | `false` | Create a prometheus-operator ServiceMonitor |
| `mailpit.metrics.serviceMonitor.interval` | `"30s"` | Scrape interval |
| `mailpit.metrics.serviceMonitor.scrapeTimeout` | `"10s"` | Scrape timeout |
| `mailpit.metrics.serviceMonitor.labels` | `{}` | Extra labels, e.g. `release: kube-prometheus-stack` |
| `extraEnv` | `[]` | Extra environment variables, e.g. any other `MP_*` option |
| `extraEnvFrom` | `[]` | Extra `envFrom` sources (ConfigMaps/Secrets) |
| `extraArgs` | `[]` | Extra container arguments |
| `extraVolumes` | `[]` | Extra volumes |
| `extraVolumeMounts` | `[]` | Extra volume mounts |
| `persistence.enabled` | `false` | Keep the database on a PersistentVolume. When disabled an `emptyDir` is used and messages are lost on restart |
| `persistence.existingClaim` | `""` | Use an existing PVC instead of a volumeClaimTemplate |
| `persistence.storageClassName` | `""` | StorageClass; empty = cluster default |
| `persistence.accessModes` | `["ReadWriteOnce"]` | Access modes |
| `persistence.size` | `"1Gi"` | Volume size |
| `persistence.annotations` | `{}` | PVC annotations |
| `persistence.retentionPolicy` | `{"whenDeleted": "Retain", "whenScaled": "Retain"}` | Keep or delete PVCs when the StatefulSet is deleted/scaled (Kubernetes >= 1.27) |
| `service.type` | `"ClusterIP"` | Service type for web UI/API and SMTP |
| `service.httpPort` | `8025` | Web UI/API port |
| `service.smtpPort` | `1025` | SMTP port |
| `service.annotations` | `{}` | Service annotations |
| `smtpService.enabled` | `false` | Create a dedicated SMTP Service |
| `smtpService.type` | `"LoadBalancer"` | Service type |
| `smtpService.annotations` | `{}` | Service annotations, e.g. `service.beta.kubernetes.io/aws-load-balancer-internal: "true"` |
| `smtpService.loadBalancerSourceRanges` | `[]` | Restrict LoadBalancer clients |
| `smtpService.externalTrafficPolicy` | `""` | External traffic policy (`Local` preserves the client IP) |
| `ingress.enabled` | `false` | Create an Ingress for the web UI/API |
| `ingress.className` | `""` | IngressClass name |
| `ingress.annotations` | `{}` | Ingress annotations |
| `ingress.hosts` | `[{"host": "mailpit.example.com"}]` | Hostnames |
| `ingress.tls` | `[]` | TLS configuration, e.g. `[{secretName: mailpit-tls, hosts: [mailpit.example.com]}]` |
| `ingress.pathType` | `"Prefix"` | Path type |
| `ingress.oauth2Proxy.enabled` | `false` | Protect the ingress with oauth2-proxy (ingress-nginx only) |
| `ingress.oauth2Proxy.url` | `"https://oauth2-proxy.example.com"` | oauth2-proxy base URL. Must be https: nginx `auth_request` does not follow redirects |
| `ingress.oauth2Proxy.allowedGroups` | `[]` | Allow only these IdP groups (`?allowed_groups=`) |
| `ingress.oauth2Proxy.allowedEmails` | `[]` | Allow only these emails (`?allowed_emails=`) |
| `ingress.oauth2Proxy.responseHeaders` | `"x-auth-request-user,x-auth-request-email,x-auth-request-groups"` | Headers passed from oauth2-proxy to Mailpit |
| `ingress.oauth2Proxy.largeBuffers` | `true` | Raise nginx proxy buffers: session cookies + auth headers overflow the 4k default |
| `httpRoute.enabled` | `false` | Create an HTTPRoute for the web UI/API |
| `httpRoute.annotations` | `{}` | HTTPRoute annotations |
| `httpRoute.parentRefs` | `[]` | Gateways to attach to, e.g. `[{name: public, namespace: gateway}]` |
| `httpRoute.hostnames` | `[]` | Hostnames |
| `httpRoute.filters` | `[]` | Extra filters |
| `networkPolicy.enabled` | `false` | Create a NetworkPolicy. Ingress is limited to the peers below, egress to DNS only |
| `networkPolicy.allowSameNamespace` | `true` | Allow all pods of the release namespace to reach the web UI and SMTP |
| `networkPolicy.httpFrom` | `[]` | Peers allowed to reach the web UI/API, e.g. the ingress controller namespace |
| `networkPolicy.smtpFrom` | `[]` | Peers allowed to send mail over SMTP |
| `networkPolicy.metricsFrom` | `[]` | Peers allowed to scrape metrics |
| `networkPolicy.egress.enabled` | `true` | Restrict egress. Mailpit is a sink: no relay, link check, webhooks or version check unless allowed below |
| `networkPolicy.egress.allowDNS` | `true` | Allow DNS to kube-dns/CoreDNS |
| `networkPolicy.egress.extra` | `[]` | Extra egress rules, e.g. a webhook receiver or SpamAssassin |
| `podSecurityContext` | `{"runAsNonRoot": true, "runAsUser": 1000, "runAsGroup": 1000, "fsGroup": 1000, "fsGroupChangePolicy": "OnRootMismatch", "seccompProfile": {"type": "RuntimeDefault"}}` | Pod security context. Compliant with the `restricted` Pod Security Standard |
| `securityContext` | `{"allowPrivilegeEscalation": false, "readOnlyRootFilesystem": true, "runAsNonRoot": true, "privileged": false, "capabilities": {"drop": ["ALL"]}}` | Container security context |
| `resources` | `{"requests": {"cpu": "10m", "memory": "64Mi"}, "limits": {"memory": "256Mi"}}` | Resource requests/limits |
| `livenessProbe.enabled` | `true` | Enable the liveness probe (`/livez`) |
| `readinessProbe.enabled` | `true` | Enable the readiness probe (`/readyz`) |
| `startupProbe.enabled` | `false` | Enable the startup probe - useful for large databases |
| `updateStrategy` | `{"type": "RollingUpdate"}` | StatefulSet update strategy |
| `podAnnotations` | `{}` | Pod annotations |
| `podLabels` | `{}` | Pod labels |
| `priorityClassName` | `""` | Priority class |
| `terminationGracePeriodSeconds` | `30` | Grace period for in-flight SMTP sessions |
| `nodeSelector` | `{}` | Node selector |
| `tolerations` | `[]` | Tolerations |
| `affinity` | `{}` | Affinity |
| `topologySpreadConstraints` | `[]` | Topology spread constraints |
| `tests.image` | `"docker.io/curlimages/curl:8.10.1"` | Image used by `helm test` |
<!-- PARAMS:END -->

## Development

```console
make lint      # helm lint + kubeconform for every ci/*.yaml values file
make docs      # regenerate the Parameters table from values.yaml comments
make test      # kind + Calico, install every ci/*.yaml values file and run helm test
```

- Every value in `values.yaml` is documented with a `# --` comment; `make docs` turns them into the table
  above. CI fails if the README is out of date.
- Bump `version` in `Chart.yaml` and update `artifacthub.io/changes` for every change. Merging to `main`
  publishes the chart to GitHub Releases, the Helm repository on GitHub Pages and
  `oci://ghcr.io/rvvg/charts`, and signs the OCI artifact with cosign.

Verify a release signature:

```console
cosign verify ghcr.io/rvvg/charts/mailpit:<version> \
  --certificate-identity-regexp 'https://github.com/rvvg/mailpit-helm/.github/workflows/release.yaml@.*' \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com
```

## License

Copyright © 2026 rvvg. Licensed under the [Apache License, Version 2.0](LICENSE).
Mailpit itself is developed by [Ralph Slooten](https://github.com/axllent) and licensed under the
[MIT License](https://github.com/axllent/mailpit/blob/develop/LICENSE).
