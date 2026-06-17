# Observability Support Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Expose ArcadeDB 26.7.1's opt-in observability stack (health probes, OTLP metrics, structured logging, distributed tracing, Prometheus discovery) as first-class Helm chart knobs.

**Architecture:** The chart passes ArcadeDB settings as `-D` JVM args in the StatefulSet `command` and wires Kubernetes resources from `values.yaml`. A new feature-grouped `observability:` values section is translated by helpers into `-D` args, a gated ServiceMonitor template, optional scrape pod annotations, and a revised liveness probe default. Every knob is default-off and behavior-preserving except the liveness probe default, which ships with the `appVersion` bump to 26.7.1.

**Tech Stack:** Helm 3 (Go templating / Sprig), helm-unittest 0.5.2, bash + kind for integration tests.

**Design spec:** `docs/superpowers/specs/2026-06-17-observability-support-design.md`

---

## Conventions for every task

- Run a single unit-test suite with: `helm unittest -f 'tests/<file>.yaml' charts/arcadedb`
  (the helm-unittest plugin auto-installs via `make plugin-install`; run that once first if `helm unittest` reports an unknown command).
- Run the whole suite with: `make test-unit`
- Lint with: `make lint`
- helm-unittest `contains`/`notContains` on a `command` list match exact strings; rendered YAML formatting/whitespace does not affect assertions.
- Commit after each green task.

---

## Task 1: Observability `-D` args helper (logging, OTLP, tracing, readiness)

Adds the four settings-only pillars: JSON logging, OTLP metrics export, tracing, and HA-aware readiness. One helper emits all of them; nothing renders when defaults are unchanged.

**Files:**
- Modify: `charts/arcadedb/values.yaml` (add `observability:` section)
- Modify: `charts/arcadedb/templates/_helpers.tpl` (add `arcadedb.observability.args`)
- Modify: `charts/arcadedb/templates/statefulset.yaml:70` (include the helper)
- Test: `charts/arcadedb/tests/observability_test.yaml` (create)

- [ ] **Step 1: Write the failing test**

Create `charts/arcadedb/tests/observability_test.yaml`:

```yaml
suite: Observability args (asserted via StatefulSet)
templates:
  - statefulset.yaml
release:
  name: test
  namespace: default
tests:
  - it: emits no observability args by default
    asserts:
      - notContains:
          path: spec.template.spec.containers[0].command
          content: "-Darcadedb.server.logFormat=json"
      - notContains:
          path: spec.template.spec.containers[0].command
          content: "-Darcadedb.serverMetrics.otlp.enabled=true"
      - notContains:
          path: spec.template.spec.containers[0].command
          content: "-Darcadedb.serverMetrics.tracing.enabled=true"
      - notContains:
          path: spec.template.spec.containers[0].command
          content: "-Darcadedb.server.readinessRequiresHA=true"

  - it: logging.format=json emits the logFormat arg
    set:
      observability.logging.format: json
    asserts:
      - contains:
          path: spec.template.spec.containers[0].command
          content: "-Darcadedb.server.logFormat=json"

  - it: text logging (default) emits no logFormat arg
    asserts:
      - notContains:
          path: spec.template.spec.containers[0].command
          content: "-Darcadedb.server.logFormat=json"

  - it: logging.includeTrace=true emits the logIncludeTrace arg
    set:
      observability.logging.includeTrace: true
    asserts:
      - contains:
          path: spec.template.spec.containers[0].command
          content: "-Darcadedb.server.logIncludeTrace=true"

  - it: otlp metrics enabled emits enable + endpoint args
    set:
      observability.metrics.otlp.enabled: true
      observability.metrics.otlp.endpoint: http://otel-collector:4317
    asserts:
      - contains:
          path: spec.template.spec.containers[0].command
          content: "-Darcadedb.serverMetrics.otlp.enabled=true"
      - contains:
          path: spec.template.spec.containers[0].command
          content: "-Darcadedb.serverMetrics.otlp.endpoint=http://otel-collector:4317"

  - it: tracing enabled emits enable + endpoint + samplingRate args
    set:
      observability.tracing.enabled: true
      observability.tracing.endpoint: http://otel-collector:4317
      observability.tracing.samplingRate: 0.1
    asserts:
      - contains:
          path: spec.template.spec.containers[0].command
          content: "-Darcadedb.serverMetrics.tracing.enabled=true"
      - contains:
          path: spec.template.spec.containers[0].command
          content: "-Darcadedb.serverMetrics.tracing.endpoint=http://otel-collector:4317"
      - contains:
          path: spec.template.spec.containers[0].command
          content: "-Darcadedb.serverMetrics.tracing.samplingRate=0.1"

  - it: readinessRequiresHA emits the arg
    set:
      observability.health.readinessRequiresHA: true
    asserts:
      - contains:
          path: spec.template.spec.containers[0].command
          content: "-Darcadedb.server.readinessRequiresHA=true"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `helm unittest -f 'tests/observability_test.yaml' charts/arcadedb`
Expected: FAIL — the `set` cases error because `observability` does not exist in values yet (nil map access), and the "emits no args" case may pass trivially.

- [ ] **Step 3: Add the `observability:` section to values.yaml**

Append to `charts/arcadedb/values.yaml` (after the `networkPolicy` section at the end):

```yaml
## @section observability
## Opt-in, behavior-preserving observability (ArcadeDB 26.7.1+).
## Every knob below defaults off; existing deployments are unchanged.
observability:
  ## @section observability.metrics
  metrics:
    prometheus:
      ## Prometheus Operator ServiceMonitor. Requires the prometheus plugin
      ## (arcadedb.plugins.prometheus.enabled=true) so /prometheus is served.
      serviceMonitor:
        ## @param observability.metrics.prometheus.serviceMonitor.enabled Create a ServiceMonitor CRD
        enabled: false
        ## @param observability.metrics.prometheus.serviceMonitor.interval Scrape interval
        interval: 30s
        ## @param observability.metrics.prometheus.serviceMonitor.scrapeTimeout Scrape timeout (empty = Prometheus default)
        scrapeTimeout: ""
        ## @param observability.metrics.prometheus.serviceMonitor.path Metrics path
        path: /prometheus
        ## @param observability.metrics.prometheus.serviceMonitor.labels Extra labels (e.g. release: kube-prometheus-stack)
        labels: {}
        ## @param observability.metrics.prometheus.serviceMonitor.annotations Extra annotations
        annotations: {}
        ## @param observability.metrics.prometheus.serviceMonitor.relabelings Prometheus relabelings
        relabelings: []
        ## @param observability.metrics.prometheus.serviceMonitor.metricRelabelings Prometheus metric relabelings
        metricRelabelings: []
        basicAuth:
          ## @param observability.metrics.prometheus.serviceMonitor.basicAuth.enabled Scrape with basic auth
          enabled: false
          ## @param observability.metrics.prometheus.serviceMonitor.basicAuth.secretName Secret holding scrape credentials (username + password keys)
          secretName: ""
          ## @param observability.metrics.prometheus.serviceMonitor.basicAuth.usernameKey Key in the secret holding the username
          usernameKey: username
          ## @param observability.metrics.prometheus.serviceMonitor.basicAuth.passwordKey Key in the secret holding the password
          passwordKey: password
      ## Annotation-based discovery (classic Prometheus, no Operator).
      podAnnotations:
        ## @param observability.metrics.prometheus.podAnnotations.enabled Add prometheus.io/* scrape annotations to pods
        enabled: false
        ## @param observability.metrics.prometheus.podAnnotations.path Scrape path annotation value
        path: /prometheus
        ## @param observability.metrics.prometheus.podAnnotations.port Scrape port (empty = service.http.port)
        port: ""
    ## Push metrics to an OpenTelemetry collector alongside /prometheus.
    otlp:
      ## @param observability.metrics.otlp.enabled Enable the OTLP metrics registry
      enabled: false
      ## @param observability.metrics.otlp.endpoint OTLP/gRPC metrics endpoint
      endpoint: http://localhost:4317
  ## @section observability.tracing
  tracing:
    ## @param observability.tracing.enabled Enable distributed tracing (plugin ships in the standard image)
    enabled: false
    ## @param observability.tracing.endpoint OTLP/gRPC trace endpoint
    endpoint: http://localhost:4317
    ## @param observability.tracing.samplingRate Parent-based sampling ratio [0.0, 1.0]
    samplingRate: 0.0
  ## @section observability.logging
  logging:
    ## @param observability.logging.format Log format: text or json
    format: text
    ## @param observability.logging.includeTrace Append [traceId=…] to text logs while a trace is active
    includeTrace: false
  ## @section observability.health
  health:
    ## @param observability.health.readinessRequiresHA /api/v1/ready waits for Raft join on HA clusters
    readinessRequiresHA: false
```

- [ ] **Step 4: Add the args helper to _helpers.tpl**

Append to `charts/arcadedb/templates/_helpers.tpl`:

```
{{/*
Observability -D JVM args (logging, OTLP metrics, tracing, readiness).
All opt-in; emits nothing when defaults are unchanged.
*/}}
{{- define "arcadedb.observability.args" -}}
{{- $o := .Values.observability -}}
{{- if eq $o.logging.format "json" }}
- -Darcadedb.server.logFormat=json
{{- end }}
{{- if $o.logging.includeTrace }}
- -Darcadedb.server.logIncludeTrace=true
{{- end }}
{{- if $o.metrics.otlp.enabled }}
- -Darcadedb.serverMetrics.otlp.enabled=true
- -Darcadedb.serverMetrics.otlp.endpoint={{ $o.metrics.otlp.endpoint }}
{{- end }}
{{- if $o.tracing.enabled }}
- -Darcadedb.serverMetrics.tracing.enabled=true
- -Darcadedb.serverMetrics.tracing.endpoint={{ $o.tracing.endpoint }}
- -Darcadedb.serverMetrics.tracing.samplingRate={{ $o.tracing.samplingRate }}
{{- end }}
{{- if $o.health.readinessRequiresHA }}
- -Darcadedb.server.readinessRequiresHA=true
{{- end }}
{{- end -}}
```

- [ ] **Step 5: Include the helper in the StatefulSet command**

In `charts/arcadedb/templates/statefulset.yaml`, find line 70:

```
            {{- include "arcadedb.plugin.parameters" . | nindent 12 }}
```

Add the observability include immediately after it:

```
            {{- include "arcadedb.plugin.parameters" . | nindent 12 }}
            {{- include "arcadedb.observability.args" . | nindent 12 }}
```

- [ ] **Step 6: Run test to verify it passes**

Run: `helm unittest -f 'tests/observability_test.yaml' charts/arcadedb`
Expected: PASS (all cases green)

- [ ] **Step 7: Lint and commit**

```bash
helm lint charts/arcadedb
git add charts/arcadedb/values.yaml charts/arcadedb/templates/_helpers.tpl charts/arcadedb/templates/statefulset.yaml charts/arcadedb/tests/observability_test.yaml
git commit -m "feat(helm): observability -D args (logging, OTLP, tracing, readiness)"
```

---

## Task 2: Prometheus plugin `requireAuthentication`

The Prometheus plugin enables `/prometheus`; scraping it from Prometheus needs unauthenticated access. Add a `requireAuthentication` knob that emits the corresponding `-D` arg.

**Files:**
- Modify: `charts/arcadedb/templates/_helpers.tpl` (the `arcadedb.plugin.parameters` define)
- Modify: `charts/arcadedb/values.yaml` (prometheus plugin example comment)
- Test: `charts/arcadedb/tests/helpers_test.yaml` (add cases)

- [ ] **Step 1: Write the failing test**

Append these tests to the `tests:` list in `charts/arcadedb/tests/helpers_test.yaml`:

```yaml
  - it: prometheus plugin emits requireAuthentication=false when set
    set:
      arcadedb.plugins.prometheus.enabled: true
      arcadedb.plugins.prometheus.requireAuthentication: false
    asserts:
      - contains:
          path: spec.template.spec.containers[0].command
          content: "-Darcadedb.serverMetrics.prometheus.requireAuthentication=false"

  - it: prometheus plugin omits requireAuthentication arg when not set
    set:
      arcadedb.plugins.prometheus.enabled: true
    asserts:
      - notContains:
          path: spec.template.spec.containers[0].command
          content: "-Darcadedb.serverMetrics.prometheus.requireAuthentication=false"
      - notContains:
          path: spec.template.spec.containers[0].command
          content: "-Darcadedb.serverMetrics.prometheus.requireAuthentication=true"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `helm unittest -f 'tests/helpers_test.yaml' charts/arcadedb`
Expected: FAIL — the requireAuthentication arg is not emitted yet.

- [ ] **Step 3: Emit the arg in the prometheus branch of `arcadedb.plugin.parameters`**

In `charts/arcadedb/templates/_helpers.tpl`, find the prometheus branch inside `arcadedb.plugin.parameters` (currently):

```
    {{- else if eq $plugin "prometheus" -}}
      {{- $plugins = append $plugins "Prometheus:com.arcadedb.metrics.prometheus.PrometheusMetricsPlugin" -}}
```

Replace it with a version that also reads `requireAuthentication` from the original values (the helper iterates over the port-map produced by `_arcadedb.plugin.ports`, which does not carry `requireAuthentication`, so read it from `.Values.arcadedb.plugins.prometheus`):

```
    {{- else if eq $plugin "prometheus" -}}
      {{- $plugins = append $plugins "Prometheus:com.arcadedb.metrics.prometheus.PrometheusMetricsPlugin" -}}
      {{- with $.Values.arcadedb.plugins.prometheus -}}
        {{- if hasKey . "requireAuthentication" -}}
          {{- $params = append $params (printf "-Darcadedb.serverMetrics.prometheus.requireAuthentication=%v" .requireAuthentication) -}}
        {{- end -}}
      {{- end -}}
```

Note: `$` is the root context. Inside the `range` the dot is the map entry, so the root values are reached via `$.Values`. `hasKey` ensures the arg is emitted only when the user explicitly sets the field (true or false), preserving the "omit when unset" behavior the test asserts.

- [ ] **Step 4: Run test to verify it passes**

Run: `helm unittest -f 'tests/helpers_test.yaml' charts/arcadedb`
Expected: PASS

- [ ] **Step 5: Document the knob in the values example**

In `charts/arcadedb/values.yaml`, update the commented prometheus plugin example (currently lines ~57-58):

```yaml
    # prometheus:
    #   enabled: false
```

to:

```yaml
    # prometheus:
    #   enabled: false
    #   # Set false to allow unauthenticated scraping of /prometheus (needed for
    #   # ServiceMonitor / annotation-based discovery without basic auth).
    #   requireAuthentication: true
```

- [ ] **Step 6: Lint and commit**

```bash
helm lint charts/arcadedb
git add charts/arcadedb/templates/_helpers.tpl charts/arcadedb/values.yaml charts/arcadedb/tests/helpers_test.yaml
git commit -m "feat(helm): prometheus plugin requireAuthentication knob"
```

---

## Task 3: Scrape pod annotations + plugin guard

Add a guard that fails fast when scrape discovery is enabled without the prometheus plugin, and merge `prometheus.io/*` annotations into the pod template when enabled.

**Files:**
- Modify: `charts/arcadedb/templates/_helpers.tpl` (add `arcadedb.observability.validate` and `arcadedb.podAnnotations`)
- Modify: `charts/arcadedb/templates/statefulset.yaml` (call guard; use merged annotations)
- Test: `charts/arcadedb/tests/observability_test.yaml` (add cases)

- [ ] **Step 1: Write the failing test**

Append to the `tests:` list in `charts/arcadedb/tests/observability_test.yaml`:

```yaml
  - it: scrape pod annotations render when enabled with the prometheus plugin
    set:
      arcadedb.plugins.prometheus.enabled: true
      observability.metrics.prometheus.podAnnotations.enabled: true
    asserts:
      - equal:
          path: spec.template.metadata.annotations["prometheus.io/scrape"]
          value: "true"
      - equal:
          path: spec.template.metadata.annotations["prometheus.io/port"]
          value: "2480"
      - equal:
          path: spec.template.metadata.annotations["prometheus.io/path"]
          value: /prometheus

  - it: scrape pod annotation port honours service.http.port and custom path
    set:
      arcadedb.plugins.prometheus.enabled: true
      service.http.port: 9090
      observability.metrics.prometheus.podAnnotations.enabled: true
      observability.metrics.prometheus.podAnnotations.path: /metrics
    asserts:
      - equal:
          path: spec.template.metadata.annotations["prometheus.io/port"]
          value: "9090"
      - equal:
          path: spec.template.metadata.annotations["prometheus.io/path"]
          value: /metrics

  - it: scrape pod annotation port can be overridden explicitly
    set:
      arcadedb.plugins.prometheus.enabled: true
      observability.metrics.prometheus.podAnnotations.enabled: true
      observability.metrics.prometheus.podAnnotations.port: 1234
    asserts:
      - equal:
          path: spec.template.metadata.annotations["prometheus.io/port"]
          value: "1234"

  - it: user podAnnotations are preserved alongside scrape annotations
    set:
      arcadedb.plugins.prometheus.enabled: true
      podAnnotations:
        my-team: data
      observability.metrics.prometheus.podAnnotations.enabled: true
    asserts:
      - equal:
          path: spec.template.metadata.annotations["my-team"]
          value: data
      - equal:
          path: spec.template.metadata.annotations["prometheus.io/scrape"]
          value: "true"

  - it: no scrape annotations when podAnnotations discovery is disabled
    asserts:
      - notExists:
          path: spec.template.metadata.annotations["prometheus.io/scrape"]

  - it: fails when scrape annotations enabled without the prometheus plugin
    set:
      observability.metrics.prometheus.podAnnotations.enabled: true
    asserts:
      - failedTemplate:
          errorPattern: "require arcadedb.plugins.prometheus.enabled=true"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `helm unittest -f 'tests/observability_test.yaml' charts/arcadedb`
Expected: FAIL — annotations are not merged and no guard exists.

- [ ] **Step 3: Add guard and annotation helpers to _helpers.tpl**

Append to `charts/arcadedb/templates/_helpers.tpl`:

```
{{/*
Guard: scrape discovery (ServiceMonitor or pod annotations) needs the
prometheus plugin so /prometheus is actually served.
*/}}
{{- define "arcadedb.observability.validate" -}}
{{- $p := .Values.observability.metrics.prometheus -}}
{{- if or $p.serviceMonitor.enabled $p.podAnnotations.enabled -}}
  {{- $promEnabled := false -}}
  {{- with .Values.arcadedb.plugins.prometheus -}}
    {{- if .enabled -}}{{- $promEnabled = true -}}{{- end -}}
  {{- end -}}
  {{- if not $promEnabled -}}
    {{- fail "observability.metrics.prometheus serviceMonitor/podAnnotations require arcadedb.plugins.prometheus.enabled=true (the /prometheus endpoint must be served)" -}}
  {{- end -}}
{{- end -}}
{{- end -}}

{{/*
Merge user-supplied podAnnotations with computed prometheus.io/* scrape
annotations. Returns YAML (possibly empty).
*/}}
{{- define "arcadedb.podAnnotations" -}}
{{- $annotations := deepCopy (default dict .Values.podAnnotations) -}}
{{- $pa := .Values.observability.metrics.prometheus.podAnnotations -}}
{{- if $pa.enabled -}}
  {{- $port := int .Values.service.http.port -}}
  {{- if $pa.port -}}{{- $port = int $pa.port -}}{{- end -}}
  {{- $_ := set $annotations "prometheus.io/scrape" "true" -}}
  {{- $_ := set $annotations "prometheus.io/port" (printf "%d" $port) -}}
  {{- $_ := set $annotations "prometheus.io/path" $pa.path -}}
{{- end -}}
{{- if $annotations -}}
{{- toYaml $annotations -}}
{{- end -}}
{{- end -}}
```

- [ ] **Step 4: Wire guard and merged annotations into statefulset.yaml**

In `charts/arcadedb/templates/statefulset.yaml`, add the guard as the very first line of the file (before `apiVersion: apps/v1`):

```
{{- include "arcadedb.observability.validate" . -}}
apiVersion: apps/v1
```

Then replace the pod-template annotations block (currently lines 18-21):

```
      {{- with .Values.podAnnotations }}
      annotations:
        {{- toYaml . | nindent 8 }}
      {{- end }}
```

with:

```
      {{- with (include "arcadedb.podAnnotations" . | fromYaml) }}
      annotations:
        {{- toYaml . | nindent 8 }}
      {{- end }}
```

(`fromYaml` of the empty string yields an empty map, so `with` correctly skips the block when there are no annotations.)

- [ ] **Step 5: Run test to verify it passes**

Run: `helm unittest -f 'tests/observability_test.yaml' charts/arcadedb`
Expected: PASS

Also re-run the existing StatefulSet suite to confirm the annotations refactor didn't regress the existing `podAnnotations flow through` test:

Run: `helm unittest -f 'tests/statefulset_test.yaml' charts/arcadedb`
Expected: PASS

- [ ] **Step 6: Lint and commit**

```bash
helm lint charts/arcadedb
git add charts/arcadedb/templates/_helpers.tpl charts/arcadedb/templates/statefulset.yaml charts/arcadedb/tests/observability_test.yaml
git commit -m "feat(helm): prometheus scrape pod annotations + plugin guard"
```

---

## Task 4: ServiceMonitor template

A gated `ServiceMonitor` for Prometheus Operator setups, selecting the existing `{fullname}-http` Service.

**Files:**
- Create: `charts/arcadedb/templates/servicemonitor.yaml`
- Modify: `charts/arcadedb/templates/_helpers.tpl` (extend guard for basicAuth secret)
- Test: `charts/arcadedb/tests/servicemonitor_test.yaml` (create)

- [ ] **Step 1: Write the failing test**

Create `charts/arcadedb/tests/servicemonitor_test.yaml`:

```yaml
suite: ServiceMonitor
templates:
  - servicemonitor.yaml
release:
  name: test
  namespace: default
tests:
  - it: is not rendered by default
    asserts:
      - hasDocuments: { count: 0 }

  - it: renders when enabled with the prometheus plugin
    set:
      arcadedb.plugins.prometheus.enabled: true
      observability.metrics.prometheus.serviceMonitor.enabled: true
    asserts:
      - hasDocuments: { count: 1 }
      - isKind: { of: ServiceMonitor }
      - equal: { path: metadata.name, value: test-arcadedb }
      - equal:
          path: spec.selector.matchLabels["app.kubernetes.io/name"]
          value: arcadedb
      - equal: { path: spec.endpoints[0].port, value: http }
      - equal: { path: spec.endpoints[0].path, value: /prometheus }
      - equal: { path: spec.endpoints[0].interval, value: 30s }

  - it: honours interval, scrapeTimeout, path, and extra labels
    set:
      arcadedb.plugins.prometheus.enabled: true
      observability.metrics.prometheus.serviceMonitor.enabled: true
      observability.metrics.prometheus.serviceMonitor.interval: 15s
      observability.metrics.prometheus.serviceMonitor.scrapeTimeout: 10s
      observability.metrics.prometheus.serviceMonitor.path: /metrics
      observability.metrics.prometheus.serviceMonitor.labels:
        release: kube-prometheus-stack
    asserts:
      - equal: { path: spec.endpoints[0].interval, value: 15s }
      - equal: { path: spec.endpoints[0].scrapeTimeout, value: 10s }
      - equal: { path: spec.endpoints[0].path, value: /metrics }
      - equal:
          path: metadata.labels.release
          value: kube-prometheus-stack

  - it: renders basicAuth referencing the supplied secret
    set:
      arcadedb.plugins.prometheus.enabled: true
      observability.metrics.prometheus.serviceMonitor.enabled: true
      observability.metrics.prometheus.serviceMonitor.basicAuth.enabled: true
      observability.metrics.prometheus.serviceMonitor.basicAuth.secretName: scrape-creds
    asserts:
      - equal:
          path: spec.endpoints[0].basicAuth.username.name
          value: scrape-creds
      - equal:
          path: spec.endpoints[0].basicAuth.username.key
          value: username
      - equal:
          path: spec.endpoints[0].basicAuth.password.name
          value: scrape-creds
      - equal:
          path: spec.endpoints[0].basicAuth.password.key
          value: password

  - it: fails when ServiceMonitor enabled without the prometheus plugin
    set:
      observability.metrics.prometheus.serviceMonitor.enabled: true
    asserts:
      - failedTemplate:
          errorPattern: "require arcadedb.plugins.prometheus.enabled=true"

  - it: fails when basicAuth enabled without a secretName
    set:
      arcadedb.plugins.prometheus.enabled: true
      observability.metrics.prometheus.serviceMonitor.enabled: true
      observability.metrics.prometheus.serviceMonitor.basicAuth.enabled: true
    asserts:
      - failedTemplate:
          errorPattern: "requires basicAuth.secretName"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `helm unittest -f 'tests/servicemonitor_test.yaml' charts/arcadedb`
Expected: FAIL — `servicemonitor.yaml` does not exist (0 documents always).

- [ ] **Step 3: Create the ServiceMonitor template**

Create `charts/arcadedb/templates/servicemonitor.yaml`:

```yaml
{{- if .Values.observability.metrics.prometheus.serviceMonitor.enabled }}
{{- include "arcadedb.observability.validate" . -}}
{{- $sm := .Values.observability.metrics.prometheus.serviceMonitor -}}
{{- if and $sm.basicAuth.enabled (not $sm.basicAuth.secretName) -}}
{{- fail "serviceMonitor.basicAuth.enabled requires basicAuth.secretName (a secret with username + password keys)" -}}
{{- end -}}
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: {{ include "arcadedb.fullname" . }}
  labels:
    {{- include "arcadedb.labels" . | nindent 4 }}
    {{- with $sm.labels }}
    {{- toYaml . | nindent 4 }}
    {{- end }}
  {{- with $sm.annotations }}
  annotations:
    {{- toYaml . | nindent 4 }}
  {{- end }}
spec:
  selector:
    matchLabels:
      {{- include "arcadedb.selectorLabels" . | nindent 6 }}
  endpoints:
    - port: http
      path: {{ $sm.path }}
      interval: {{ $sm.interval }}
      {{- with $sm.scrapeTimeout }}
      scrapeTimeout: {{ . }}
      {{- end }}
      {{- if $sm.basicAuth.enabled }}
      basicAuth:
        username:
          name: {{ $sm.basicAuth.secretName }}
          key: {{ $sm.basicAuth.usernameKey }}
        password:
          name: {{ $sm.basicAuth.secretName }}
          key: {{ $sm.basicAuth.passwordKey }}
      {{- end }}
      {{- with $sm.relabelings }}
      relabelings:
        {{- toYaml . | nindent 8 }}
      {{- end }}
      {{- with $sm.metricRelabelings }}
      metricRelabelings:
        {{- toYaml . | nindent 8 }}
      {{- end }}
{{- end }}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `helm unittest -f 'tests/servicemonitor_test.yaml' charts/arcadedb`
Expected: PASS

- [ ] **Step 5: Lint and commit**

```bash
helm lint charts/arcadedb
git add charts/arcadedb/templates/servicemonitor.yaml charts/arcadedb/tests/servicemonitor_test.yaml
git commit -m "feat(helm): optional Prometheus Operator ServiceMonitor"
```

---

## Task 5: Liveness probe default + appVersion bump to 26.7.1

Switch the default liveness probe to the dependency-free `/api/v1/health` (exists in 26.7.1+) and move chart `version`/`appVersion` to 26.7.1 so the default image serves it. Readiness stays on `/api/v1/ready`.

**Files:**
- Modify: `charts/arcadedb/values.yaml` (livenessProbe path)
- Modify: `charts/arcadedb/Chart.yaml` (version + appVersion)
- Modify: `charts/arcadedb/tests/statefulset_test.yaml` (probe + image-literal assertions)

- [ ] **Step 1: Update the failing assertions in statefulset_test.yaml**

In `charts/arcadedb/tests/statefulset_test.yaml`, replace the probe test (currently the `it: liveness and readiness probes default to /api/v1/ready on http port` block, lines ~104-117) with:

```yaml
  - it: liveness probe defaults to /api/v1/health and readiness to /api/v1/ready
    asserts:
      - equal:
          path: "spec.template.spec.containers[0].livenessProbe.httpGet.path"
          value: /api/v1/health
      - equal:
          path: "spec.template.spec.containers[0].livenessProbe.httpGet.port"
          value: http
      - equal:
          path: "spec.template.spec.containers[0].readinessProbe.httpGet.path"
          value: /api/v1/ready
      - equal:
          path: "spec.template.spec.containers[0].readinessProbe.httpGet.port"
          value: http
```

In the same file, update the two pinned image literals from `26.6.1` to `26.7.1`:
- `it: image string composes registry/repository:tag, defaulting tag to AppVersion` → `value: arcadedata/arcadedb:26.7.1`
- `it: image.registry and image.repository overrides flow through` → `value: my-registry.example.com/arcadedb-fork:26.7.1`

- [ ] **Step 2: Run test to verify it fails**

Run: `helm unittest -f 'tests/statefulset_test.yaml' charts/arcadedb`
Expected: FAIL — liveness still renders `/api/v1/ready` and image is still `26.6.1`.

- [ ] **Step 3: Change the liveness probe default**

In `charts/arcadedb/values.yaml`, update the `livenessProbe` section:

```yaml
## @section livenessProbe
## Liveness uses the dependency-free /api/v1/health endpoint (no DB I/O,
## never returns 503). Requires ArcadeDB 26.7.1+.
livenessProbe:
  httpGet:
    path: /api/v1/health
    port: http
```

Leave `readinessProbe` pointing at `/api/v1/ready` unchanged.

- [ ] **Step 4: Bump the chart version and appVersion**

In `charts/arcadedb/Chart.yaml`, change both:

```yaml
version: 26.7.1
appVersion: "26.7.1"
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `helm unittest -f 'tests/statefulset_test.yaml' charts/arcadedb`
Expected: PASS

Run: `make test-unit`
Expected: PASS (full suite green)

- [ ] **Step 6: Lint and commit**

```bash
helm lint charts/arcadedb
git add charts/arcadedb/values.yaml charts/arcadedb/Chart.yaml charts/arcadedb/tests/statefulset_test.yaml
git commit -m "feat(helm): default liveness to /api/v1/health; bump to 26.7.1"
```

> **Merge gate:** the PR integration job pulls the default `image.tag` (now `26.7.1`). It goes green only once `arcadedata/arcadedb:26.7.1` is published. Until then, the `latest-image` guard (which pins `:latest`, where the features already live) validates the new behavior. Do not merge/release the chart before the 26.7.1 image exists.

---

## Task 6: Integration test — `/api/v1/health` liveness smoke

Add one phase to the shared kind integration script asserting the new liveness endpoint returns HTTP 204. It runs in both the PR job and the latest-image guard.

**Files:**
- Modify: `ci/integration-test.sh`

- [ ] **Step 1: Add an unauthenticated 204 health-probe helper and phase**

In `ci/integration-test.sh`, after the `api()` helper (around line 42), add a helper that asserts the liveness endpoint returns 204 with no auth:

```bash
assert_health_204() {   # assert_health_204 <local-port>
  local port=$1 code
  code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 \
    "http://localhost:${port}/api/v1/health")
  if [[ "$code" != "204" ]]; then
    echo "ERROR: /api/v1/health returned ${code}, expected 204"
    return 1
  fi
  echo "    /api/v1/health -> 204 (unauthenticated liveness OK)"
  return 0
}
```

- [ ] **Step 2: Renumber phase headers and insert the health phase**

The script currently runs 6 phases labelled `[1/6]`…`[6/6]`. Bump the count to 7 and insert the health phase as phase 2 (right after rollout, before Raft formation). Update the six existing `==> [N/6]` echo lines to `[N/7]` with their numbers shifted by one for phases after the new one. Concretely:

- Keep phase 1 (rollout) as `==> [1/7] Waiting for StatefulSet rollout ...`.
- Insert immediately after the rollout phase (after its `echo "    All 3 pods Ready."` line, ~line 137):

```bash
# ── phase 2: liveness health probe ────────────────────────────────────────────

echo "==> [2/7] Asserting /api/v1/health liveness endpoint..."
HP_PID=$(pf_start 0 "$HTTP_PORT")
pf_wait "$HTTP_PORT" || { echo "ERROR: port-forward to pod-0 failed"; exit 1; }
assert_health_204 "$HTTP_PORT" || exit 1
pf_stop "$HP_PID"
```

- Renumber the remaining phase banners: Raft formation `[2/6]`→`[3/7]`, write `[3/6]`→`[4/7]`, read `[4/6]`→`[5/7]`, STATUS `[5/6]`→`[6/7]`, leadership transfer `[6/6]`→`[7/7]`.

- [ ] **Step 3: Verify the script is syntactically valid**

Run: `bash -n ci/integration-test.sh`
Expected: no output, exit 0.

(The full kind run executes in CI; locally it requires Docker + kind. `bash -n` confirms syntax without a cluster.)

- [ ] **Step 4: Commit**

```bash
git add ci/integration-test.sh
git commit -m "test(integration): assert /api/v1/health liveness returns 204"
```

---

## Task 7: Documentation

Document the new knobs in the chart README param table and add enable recipes to the top-level README.

**Files:**
- Modify: `charts/arcadedb/README.md` (params table)
- Modify: `README.md` (Observability section)

- [ ] **Step 1: Add the observability params to the chart README**

Open `charts/arcadedb/README.md`, locate the parameters table, and add an `### observability` subsection that follows the existing table style (`| Name | Description | Value |`). Use these rows:

```markdown
### observability

| Name                                                                      | Description                                                      | Value                    |
| ------------------------------------------------------------------------- | ---------------------------------------------------------------- | ------------------------ |
| `observability.metrics.prometheus.serviceMonitor.enabled`                 | Create a Prometheus Operator ServiceMonitor                      | `false`                  |
| `observability.metrics.prometheus.serviceMonitor.interval`                | Scrape interval                                                  | `30s`                    |
| `observability.metrics.prometheus.serviceMonitor.scrapeTimeout`           | Scrape timeout (empty = Prometheus default)                      | `""`                     |
| `observability.metrics.prometheus.serviceMonitor.path`                    | Metrics path                                                     | `/prometheus`            |
| `observability.metrics.prometheus.serviceMonitor.labels`                  | Extra labels (e.g. release: kube-prometheus-stack)              | `{}`                     |
| `observability.metrics.prometheus.serviceMonitor.annotations`             | Extra annotations                                                | `{}`                     |
| `observability.metrics.prometheus.serviceMonitor.relabelings`             | Prometheus relabelings                                           | `[]`                     |
| `observability.metrics.prometheus.serviceMonitor.metricRelabelings`       | Prometheus metric relabelings                                    | `[]`                     |
| `observability.metrics.prometheus.serviceMonitor.basicAuth.enabled`       | Scrape with basic auth                                           | `false`                  |
| `observability.metrics.prometheus.serviceMonitor.basicAuth.secretName`    | Secret with scrape credentials (username + password keys)        | `""`                     |
| `observability.metrics.prometheus.serviceMonitor.basicAuth.usernameKey`   | Secret key holding the username                                  | `username`               |
| `observability.metrics.prometheus.serviceMonitor.basicAuth.passwordKey`   | Secret key holding the password                                  | `password`               |
| `observability.metrics.prometheus.podAnnotations.enabled`                 | Add prometheus.io/* scrape annotations to pods                   | `false`                  |
| `observability.metrics.prometheus.podAnnotations.path`                    | Scrape path annotation value                                     | `/prometheus`            |
| `observability.metrics.prometheus.podAnnotations.port`                    | Scrape port (empty = service.http.port)                          | `""`                     |
| `observability.metrics.otlp.enabled`                                      | Enable the OTLP metrics registry                                 | `false`                  |
| `observability.metrics.otlp.endpoint`                                     | OTLP/gRPC metrics endpoint                                       | `http://localhost:4317`  |
| `observability.tracing.enabled`                                           | Enable distributed tracing                                       | `false`                  |
| `observability.tracing.endpoint`                                          | OTLP/gRPC trace endpoint                                         | `http://localhost:4317`  |
| `observability.tracing.samplingRate`                                      | Parent-based sampling ratio [0.0, 1.0]                           | `0.0`                    |
| `observability.logging.format`                                            | Log format: text or json                                        | `text`                   |
| `observability.logging.includeTrace`                                      | Append [traceId=…] to text logs while a trace is active          | `false`                  |
| `observability.health.readinessRequiresHA`                                | /api/v1/ready waits for Raft join on HA clusters                 | `false`                  |
```

If the repo has a README-generator config (e.g. a `readme-generator` step), regenerate instead of hand-editing; otherwise hand-edit to match the table format above.

- [ ] **Step 2: Add an Observability section to the top-level README**

In `README.md`, after the `## Configuration` section, add:

```markdown
## Observability

ArcadeDB 26.7.1+ exposes opt-in, behavior-preserving observability. All knobs
default off.

**Prometheus scraping (Operator):**

```bash
helm install my-arcadedb arcadedb/arcadedb \
  --set arcadedb.plugins.prometheus.enabled=true \
  --set arcadedb.plugins.prometheus.requireAuthentication=false \
  --set observability.metrics.prometheus.serviceMonitor.enabled=true \
  --set observability.metrics.prometheus.serviceMonitor.labels.release=kube-prometheus-stack
```

For non-Operator Prometheus, use annotation discovery instead:
`--set observability.metrics.prometheus.podAnnotations.enabled=true`.

**OTLP metrics export** (alongside /prometheus):

```bash
--set observability.metrics.otlp.enabled=true \
--set observability.metrics.otlp.endpoint=http://otel-collector:4317
```

**Distributed tracing:**

```bash
--set observability.tracing.enabled=true \
--set observability.tracing.endpoint=http://otel-collector:4317 \
--set observability.tracing.samplingRate=0.1
```

**Structured JSON logging:** `--set observability.logging.format=json`

The liveness probe uses the dependency-free `/api/v1/health` endpoint;
readiness stays on `/api/v1/ready`. Set
`observability.health.readinessRequiresHA=true` to gate readiness on Raft
membership in HA clusters.
```

- [ ] **Step 3: Lint and commit**

```bash
helm lint charts/arcadedb
git add charts/arcadedb/README.md README.md
git commit -m "docs: document observability configuration"
```

---

## Final verification

- [ ] **Run the full unit suite and lint**

Run: `make lint && make test-unit`
Expected: lint clean; all suites pass.

- [ ] **Confirm the rendered manifests for a fully-enabled config**

Run:
```bash
helm template t charts/arcadedb \
  --set arcadedb.plugins.prometheus.enabled=true \
  --set arcadedb.plugins.prometheus.requireAuthentication=false \
  --set observability.metrics.prometheus.serviceMonitor.enabled=true \
  --set observability.metrics.prometheus.podAnnotations.enabled=true \
  --set observability.metrics.otlp.enabled=true \
  --set observability.tracing.enabled=true \
  --set observability.logging.format=json \
  --set observability.health.readinessRequiresHA=true
```
Expected: a ServiceMonitor document renders; the StatefulSet command contains the otlp/tracing/logFormat/readinessRequiresHA/requireAuthentication `-D` args; pod template has `prometheus.io/*` annotations; liveness path is `/api/v1/health`.

---

## Notes for the implementer

- **TDD discipline:** each task writes/updates the test first, watches it fail, then implements. Do not skip the "verify it fails" step — it proves the test exercises the new behavior.
- **The guard runs on every render.** `arcadedb.observability.validate` is invoked from both `statefulset.yaml` (top of file) and `servicemonitor.yaml`. A misconfiguration (`serviceMonitor`/`podAnnotations` enabled without the prometheus plugin) fails `helm template`/`install` fast with a clear message — this is intended.
- **basicAuth uses a user-supplied secret**, not the chart's managed `arcadedb-credentials-secret` (which holds only `rootPassword`, no username key). The documented happy path is unauthenticated scraping via `requireAuthentication=false`.
- **Version coupling:** Task 5 is the only one changing a default. Keep it as a single commit so the liveness-default change and the 26.7.1 bump move together, and respect the merge gate.
```
