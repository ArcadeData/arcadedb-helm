# Design: Observability support for the ArcadeDB Helm chart

**Date:** 2026-06-17
**Status:** Approved
**Tracking:** ArcadeData/arcadedb#4463 (sub-issues #4464, #4465, #4466, #4467)

## Summary

ArcadeDB 26.7.1 adds an opt-in, behavior-preserving observability stack across four
pillars: dependency-free health probes (#4464), metrics depth with OTLP export
(#4465), structured JSON logging with correlation/trace IDs (#4466), and distributed
tracing (#4467). All features are present in the `latest` image today and ship in the
`26.7.1` release.

This chart is a thin wrapper that passes ArcadeDB settings as `-D` JVM args in the
StatefulSet `command`, wires plugins through `_helpers.tpl`, and exposes ports through
the services. Supporting observability therefore means: a first-class `observability:`
values surface, helpers that translate it into `-D` args, a new ServiceMonitor template,
optional scrape annotations, a revised liveness probe default, and tests/docs.

Everything is default-off and behavior-preserving except the liveness probe default,
which changes together with the `appVersion` bump to `26.7.1` (see Health pillar).

## Goals

- Expose all four observability pillars as documented, validated, first-class chart knobs.
- Provide Kubernetes-native Prometheus discovery the raw `-D` args cannot: a
  ServiceMonitor CRD and scrape annotations.
- Improve the liveness probe to a dependency-free endpoint that cannot trigger
  restart loops on slow startup.
- Keep existing deployments unchanged when the new knobs are left at their defaults.

## Non-goals

- Standing up an OTel collector or Prometheus Operator inside the chart — users point
  the chart at their own.
- Heavy end-to-end CI for collectors/operators in kind. Rendering is covered by unit
  tests; a single `/api/v1/health` smoke assertion is added to the existing kind job.
- A generic settings passthrough. The existing `arcadedb.extraCommands` remains the
  escape hatch for any setting not promoted to a first-class knob.

## Design choice

The values surface is a **dedicated, feature-grouped `observability:` section** rather
than a 1:1 mirror of ArcadeDB's internal key hierarchy or a raw passthrough map. This
matches how the chart already abstracts plugins and persistence into purpose-built
sections, gives a cleanly testable surface, and keeps documentation focused. Templates
translate the chart-level knobs into the underlying ArcadeDB `-D` settings.

**Boundary:** the Prometheus *plugin* (what loads `/prometheus` inside ArcadeDB) stays
under the existing `arcadedb.plugins.prometheus`, consistent with every other plugin.
The `observability.metrics.prometheus.*` block handles only the Kubernetes-side
integration (ServiceMonitor + annotations). A template guard fails with a clear message
if a ServiceMonitor or scrape annotations are enabled while the prometheus plugin is off.

## Components

### 1. Values surface (`values.yaml`)

New top-level block; all knobs default-off / behavior-preserving:

```yaml
## @section observability
observability:
  metrics:
    prometheus:
      serviceMonitor:
        enabled: false
        interval: 30s
        scrapeTimeout: ""
        path: /prometheus
        labels: {}            # e.g. release: kube-prometheus-stack
        annotations: {}
        relabelings: []
        metricRelabelings: []
        basicAuth:
          enabled: false      # scrape with root creds from the chart-managed secret
      podAnnotations:
        enabled: false        # classic annotation-based discovery (no Operator)
        path: /prometheus
        # port defaults to service.http.port
    otlp:
      enabled: false
      endpoint: http://localhost:4317
  tracing:
    enabled: false
    endpoint: http://localhost:4317
    samplingRate: 0.0         # parent-based ratio [0.0, 1.0]
  logging:
    format: text              # text | json
    includeTrace: false       # append [traceId=…] to text logs
  health:
    readinessRequiresHA: false # /api/v1/ready waits for Raft join on HA clusters
```

The existing `arcadedb.plugins.prometheus` example is extended with a
`requireAuthentication` knob.

### 2. Template translation (`_helpers.tpl`, `statefulset.yaml`)

A new helper `arcadedb.observability.args` emits the `-D` args, included in the
StatefulSet `command` after the existing plugin parameters:

| Knob | Emitted `-D` arg(s) |
|------|---------------------|
| `logging.format: json` | `-Darcadedb.server.logFormat=json` |
| `logging.includeTrace: true` | `-Darcadedb.server.logIncludeTrace=true` |
| `metrics.otlp.enabled: true` | `-Darcadedb.serverMetrics.otlp.enabled=true` + `...otlp.endpoint=<endpoint>` |
| `tracing.enabled: true` | `...tracing.enabled=true` + `...tracing.endpoint=<endpoint>` + `...tracing.samplingRate=<rate>` |
| `health.readinessRequiresHA: true` | `-Darcadedb.server.readinessRequiresHA=true` |

Plus:
- `_arcadedb.plugin.ports` / `arcadedb.plugin.parameters` extended so
  `arcadedb.plugins.prometheus.requireAuthentication: false` emits
  `-Darcadedb.serverMetrics.prometheus.requireAuthentication=false`.
- StatefulSet pod-template `metadata.annotations` merges `.Values.podAnnotations` with
  computed `prometheus.io/scrape|port|path` annotations when
  `observability.metrics.prometheus.podAnnotations.enabled` is true (port defaults to
  `service.http.port`).

### 3. ServiceMonitor (`templates/servicemonitor.yaml`, new)

Gated on `observability.metrics.prometheus.serviceMonitor.enabled`. Selects the existing
`{fullname}-http` Service via the chart's standard selector labels and scrapes its named
`http` port at the configured path — no new Service or port. Optional `basicAuth`
references the chart's root credential secret (username `root`) so an authenticated
`/prometheus` can still be scraped; default off, with the documented happy path being
`arcadedb.plugins.prometheus.requireAuthentication: false` + unauthenticated scrape.
Supports `labels`, `annotations`, `interval`, `scrapeTimeout`, `relabelings`,
`metricRelabelings`. Fully gated, so clusters without the Operator CRD are unaffected
when disabled.

### 4. Guard helper

A small helper invoked from both the ServiceMonitor template and the StatefulSet that
calls `fail` with a clear message if `serviceMonitor.enabled` or
`podAnnotations.enabled` is true while `arcadedb.plugins.prometheus.enabled` is not.

### 5. Health probes (`values.yaml`)

```yaml
livenessProbe:
  httpGet:
    path: /api/v1/health   # was /api/v1/ready — liveness must not depend on DB state
    port: http
readinessProbe:
  httpGet:
    path: /api/v1/ready    # unchanged — gates traffic until ONLINE
    port: http
```

`/api/v1/health` does no DB I/O and never returns 503, eliminating the restart-loop risk
of liveness depending on `/api/v1/ready`. This endpoint exists only in `26.7.1`+, so the
default change ships together with the `appVersion` bump. It is the single
default-changing item in this design; every other knob is default-off and harmless on
older images.

### 6. Version (`Chart.yaml`)

`version` and `appVersion` → `26.7.1`. The default `image.tag` then resolves to an image
that serves `/api/v1/health`, keeping chart and image consistent. Prepared against
`latest` (== 26.7.1 content), released when 26.7.1 publishes.

## Testing

helm-unittest, one file per concern (existing chart convention):

- `tests/observability_test.yaml` (new): each knob renders the correct `-D` arg and
  nothing when default-off — logging json/text, otlp on/off, tracing args incl.
  `samplingRate`, `readinessRequiresHA`, the prometheus `requireAuthentication` arg, and
  the pod scrape annotations.
- `tests/servicemonitor_test.yaml` (new): CRD absent when disabled; correct
  selector/port/path/interval, `basicAuth` block, labels; and the `fail` guard when
  enabled without the prometheus plugin.
- `tests/statefulset_test.yaml` (update): liveness default `/api/v1/health`, readiness
  unchanged.
- `tests/helpers_test.yaml` (update): plugin `requireAuthentication` rendering.

CI: the existing kind integration job already runs `latest`; add one assertion phase
that curls `/api/v1/health` and expects HTTP 204, locking in the new liveness contract.
Collector/Operator end-to-end scenarios are out of scope.

## Documentation

- `@section`/`@param` annotations across the new values so the readme-generator emits
  them; regenerate `charts/arcadedb/README.md`.
- A short "Observability" subsection in the top-level `README.md` with enable recipes:
  Prometheus + ServiceMonitor, OTLP metrics, distributed tracing, and JSON logging.

## Files touched

- `charts/arcadedb/values.yaml` — new `observability:` section; `requireAuthentication`
  on the prometheus plugin example; revised liveness probe default.
- `charts/arcadedb/templates/_helpers.tpl` — `arcadedb.observability.args` helper,
  plugin `requireAuthentication`, guard helper.
- `charts/arcadedb/templates/statefulset.yaml` — include observability args; merge scrape
  pod annotations.
- `charts/arcadedb/templates/servicemonitor.yaml` — new, gated.
- `charts/arcadedb/Chart.yaml` — `version`/`appVersion` → `26.7.1`.
- `charts/arcadedb/tests/observability_test.yaml`, `tests/servicemonitor_test.yaml` — new.
- `charts/arcadedb/tests/statefulset_test.yaml`, `tests/helpers_test.yaml` — updated.
- `charts/arcadedb/README.md`, `README.md` — regenerated/updated docs.
- kind integration job — one `/api/v1/health` smoke assertion.

## Risks & mitigations

- **Version skew (liveness 404 on < 26.7.1):** mitigated by bumping `appVersion` to
  `26.7.1` so the default image serves the endpoint; release the chart only when the
  image is published.
- **ServiceMonitor without the Operator CRD:** template fully gated; no effect when
  disabled.
- **Scrape config without the prometheus plugin:** guard helper fails fast with guidance.
- **Authenticated `/prometheus` blocking scrapes:** documented happy path disables
  prometheus auth; optional `basicAuth` covers the authenticated case.
