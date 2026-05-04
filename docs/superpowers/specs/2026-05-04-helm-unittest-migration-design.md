# Helm Unittest Migration — Design

**Date:** 2026-05-04
**Status:** Approved (pending implementation plan)
**Branch:** `feat/migrate-to-heml-unittest`

## Goal

Replace the current ad-hoc `helm template … | grep` style template checks in
`.github/workflows/lint.yml` with proper unit tests authored in
[helm-unittest](https://github.com/helm-unittest/helm-unittest), and use the
migration as an opportunity to expand coverage to all chart templates and
their conditional branches.

## Non-Goals

- Replacing the kind-based integration test (`ci/integration-test.sh`). It runs
  in a separate CI job and stays as-is.
- Replacing `helm lint`. It stays.
- Snapshot testing. Excluded by design — see Decisions.
- Refactoring chart templates. Targeted improvements only if a test reveals a
  bug; otherwise the migration preserves existing behavior.

## Context

The chart `charts/arcadedb` contains nine template files (StatefulSet, Service,
HPA, Ingress, NetworkPolicy, Secret, ServiceAccount, NOTES.txt, plus
`extra-manifests.yaml` and `_helpers.tpl`). The current CI workflow
`.github/workflows/lint.yml` exercises the chart through:

1. `helm lint`
2. Six `helm template …` smoke renders, most piped to `> /dev/null`
3. One `helm template … | grep -q "kind: HorizontalPodAutoscaler"` positive check
4. One bash incantation that asserts `helm template` *fails* with a "quorum"
   message when HPA is misconfigured
5. A separate kind-based integration job

Items 2–4 are template-level checks: they only validate that templates render
(or fail-render) under a given input. They are exactly the use case
helm-unittest is designed for. The current set of checks covers a small
fraction of the chart's conditional branches — most templates render only as
"renders without error" smoke tests, with no assertions on what they actually
produce.

## Decisions

| # | Decision | Rationale |
|---|----------|-----------|
| 1 | Full coverage push (not minimal port) | Existing checks are very thin; a 1:1 port leaves the chart effectively untested while the migration cost has already been paid. |
| 2 | Replace existing template checks; split CI into `lint` / `unittest` / `integration` jobs | Single source of truth for template assertions; clear failure attribution per job. |
| 3 | One suite per template file, plus one cross-cutting `quorum_guard_test.yaml` for `fail`-based invariants | Community convention; each failure points straight at one template. The cross-cutting suite captures invariants that span templates or are pure helper-level fail conditions. |
| 4 | Explicit assertions only — no snapshot testing | Snapshots get either blindly regenerated or produce noisy diffs on intentional refactors. Explicit assertions self-document intent and produce meaningful PR diffs. |
| 5 | Plugin-install (pinned) + Makefile entry points | One canonical command per check kind; CI and local environments stay aligned via a single pinned version. |

## Architecture

### File Layout

```
arcadedb-helm/
├── charts/arcadedb/
│   ├── templates/                 # unchanged
│   ├── tests/                     # NEW — helm-unittest suites
│   │   ├── statefulset_test.yaml
│   │   ├── service_test.yaml
│   │   ├── hpa_test.yaml
│   │   ├── ingress_test.yaml
│   │   ├── networkpolicy_test.yaml
│   │   ├── secret_test.yaml
│   │   ├── serviceaccount_test.yaml
│   │   ├── notes_test.yaml
│   │   ├── helpers_test.yaml
│   │   ├── extra_manifests_test.yaml
│   │   └── quorum_guard_test.yaml
│   └── .helmignore                # add 'tests/' so the directory is excluded from packages
├── .github/workflows/lint.yml     # restructured: lint / unittest / integration
├── ci/integration-test.sh         # unchanged
├── Makefile                       # NEW
└── README.md                      # add short "Development" section
```

`tests/` lives inside the chart directory (helm-unittest convention) but is
excluded from the packaged tarball via `.helmignore`, so it never ships to
`helm.arcadedb.com`.

`_helpers.tpl` cannot be rendered directly by helm-unittest — its outputs are
asserted through whichever consuming template is most natural (typically
`statefulset.yaml`). The `helpers_test.yaml` suite contains those assertions
and is named for the helper being verified, not for the rendered template.

### Test Conventions

All suites share these conventions:

- Top-level `release: { name: test, namespace: default }` — fixes
  `arcadedb.fullname` to `test-arcadedb` across all assertions.
- `templates: [<file>]` at the top of each suite — scopes rendering, isolates
  failures.
- One `it:` block per assertion *intent*; multiple `asserts:` inside one block
  when they verify the same intent (e.g., "HPA renders correctly" can group
  kind / min / max / scaleTargetRef checks).
- Prefer `equal` with explicit `path:` over `matchRegex` — clearer failure
  messages and stable across whitespace/ordering changes.
- Use `contains` with `content:` block for list-item assertions (metrics,
  ports, env vars).
- Use `notContains` / `notExists` / `hasDocuments: { count: 0 }` for
  negative-case assertions.
- Use `failedTemplate: { errorMessage: ... }` for `fail`-based invariants;
  match the exact error string the template produces.
- No `matchSnapshot`.

### Example Test File

```yaml
# charts/arcadedb/tests/hpa_test.yaml
suite: HorizontalPodAutoscaler
templates:
  - hpa.yaml
release:
  name: test
  namespace: default
tests:
  - it: is not rendered by default
    asserts:
      - hasDocuments: { count: 0 }

  - it: renders with valid quorum
    set:
      autoscaling.enabled: true
      autoscaling.minReplicas: 3
      autoscaling.maxReplicas: 5
    asserts:
      - hasDocuments: { count: 1 }
      - isKind: { of: HorizontalPodAutoscaler }
      - equal: { path: spec.minReplicas, value: 3 }
      - equal: { path: spec.maxReplicas, value: 5 }
      - equal: { path: spec.scaleTargetRef.name, value: test-arcadedb }

  - it: includes CPU metric when configured
    set:
      autoscaling.enabled: true
      autoscaling.minReplicas: 3
      autoscaling.maxReplicas: 5
      autoscaling.targetCPUUtilizationPercentage: 80
    asserts:
      - contains:
          path: spec.metrics
          content:
            type: Resource
            resource:
              name: cpu
              target:
                type: Utilization
                averageUtilization: 80
```

Fail-assertion example (from `quorum_guard_test.yaml`):

```yaml
  - it: fails when minReplicas violates quorum
    set:
      autoscaling.enabled: true
      autoscaling.minReplicas: 1
      autoscaling.maxReplicas: 5
    asserts:
      - failedTemplate:
          errorMessage: |-
            autoscaling.minReplicas (1) must be >= floor(maxReplicas/2)+1 (3) to maintain Raft quorum with maxReplicas=5. Increase minReplicas or decrease maxReplicas.
```

## Per-Suite Coverage

Approximate test counts are targets — the implementation plan may merge or
split blocks where it improves clarity. Total target: ~80 explicit tests.

### `statefulset_test.yaml` (~25–30 tests)

- Default render: name, common labels, selector labels, `serviceName`,
  `replicas: 1`, image string composition (`registry/repository:tag`,
  fallback to `.Chart.AppVersion` when `image.tag` empty).
- Probe wiring: `livenessProbe` and `readinessProbe` present with default
  `/api/v1/ready` httpGet on the `http` named port.
- HA-mode toggle via `replicaCount`: `replicaCount > 1` adds the
  `-Darcadedb.ha.*` flags; `replicaCount = 1` does NOT.
- HA-mode toggle via autoscaling: `autoscaling.enabled = true` triggers HA
  flags even with `replicaCount = 1`.
- Container ports: `http` (default 2480) and `rpc` (default 2434) present;
  customizable via `service.http.port` / `service.rpc.port`.
- Persistence enabled: `arcadedb-data` volumeMount and volumeClaimTemplate
  rendered; `storageClass`, `size`, `accessMode` flow through.
- Persistence disabled: volumeMount and volumeClaimTemplate absent.
- Secret wiring: default uses `arcadedb-credentials-secret`; user-supplied
  `arcadedb.credentials.rootPassword.secret.{name,key}` override it.
- Optional fields render when set, are absent when empty:
  `imagePullSecrets`, `podAnnotations`, `podLabels`, `volumes`, `volumeMounts`,
  `nodeSelector`, `affinity`, `tolerations`, `resources`,
  `arcadedb.extraEnvironment`, `arcadedb.extraCommands`,
  `volumeClaimTemplates`.
- Security context: pod-level (`runAsNonRoot`, `fsGroup`) and container-level
  (`runAsUser`, `runAsGroup`, `allowPrivilegeEscalation`, `capabilities.drop`)
  defaults render; overrides flow through.
- ServiceAccount name selection: matches `serviceAccount.name` override; falls
  back to `arcadedb.fullname`; falls back to `default` when
  `serviceAccount.create = false` and no name set.
- Plugin command parameters: gremlin, postgres, mongo, redis, prometheus, and
  custom plugins each contribute the correct `-Darcadedb.server.plugins=…`
  entry and (where applicable) port flags; disabled plugins are absent;
  prometheus contributes a plugin entry but no port flag.

### `service_test.yaml` (~10 tests)

- Default render: `ClusterIP`, http port 2480 named `http`, rpc port 2434
  named `rpc`.
- `service.http.type` override to `LoadBalancer` honored.
- Plugin port projection through `arcadedb.plugin.service` helper: each
  enabled plugin (gremlin, postgres, mongo, redis) adds a service port with
  the correct name and number.
- Prometheus does NOT add a service port (port = -1 sentinel case).
- Custom plugin port appears.
- Selector matches StatefulSet selector labels.
- `service.http.port` and `service.rpc.port` overrides flow through.

### `hpa_test.yaml` (~8 tests)

- Disabled by default → no HPA rendered.
- Enabled with valid quorum → HPA renders with correct `minReplicas`,
  `maxReplicas`, `scaleTargetRef.{kind,name,apiVersion}`.
- CPU metric present when `targetCPUUtilizationPercentage` set; absent when
  null.
- Memory metric present when `targetMemoryUtilizationPercentage` set; absent
  by default.
- `scaleTargetRef.name` matches the StatefulSet's name (i.e.,
  `arcadedb.fullname`).

Quorum-fail cases are owned by `quorum_guard_test.yaml`.

### `quorum_guard_test.yaml` (~5 tests)

Cross-cutting fail-assertion suite. Covers `fail`-based invariants that span
templates or live in helpers.

- HPA: `minReplicas = 1, maxReplicas = 5` → fails with "quorum" message.
- HPA: `minReplicas = 2, maxReplicas = 5` → fails (boundary:
  `floor(5/2)+1 = 3`, so 2 violates).
- HPA: `minReplicas = 3, maxReplicas = 5` → succeeds (lower boundary).
- HPA: `minReplicas = 2, maxReplicas = 3` → succeeds (`floor(3/2)+1 = 2`).
- Custom plugin defined with no `port` and no `class` → fails with
  "no port specified" message (asserted through `statefulset.yaml`).

### `ingress_test.yaml` (~6 tests)

- Disabled by default → no Ingress.
- Enabled → renders with default host, path, pathType.
- `ingress.className` honored when set.
- `ingress.annotations` flow through.
- `ingress.tls` section flows through when set.
- Multiple hosts/paths render correctly.

### `networkpolicy_test.yaml` (~6 tests)

- Disabled by default → no NetworkPolicy.
- Enabled → policy renders with HTTP (2480) ingress open to all cluster pods.
- Enabled → policy renders with RPC (2434) ingress restricted to ArcadeDB
  pods only via selector.
- Selector targets ArcadeDB pods (matches StatefulSet selector labels).
- Egress rules render as defined in the template.
- Custom `service.http.port` / `service.rpc.port` flow through to the policy.

### `secret_test.yaml` (~4 tests)

- Default → auto-generated `arcadedb-credentials-secret` rendered with a
  `rootPassword` key.
- User-supplied `arcadedb.credentials.rootPassword.secret.name` → no Secret
  rendered (chart consumes the existing one).
- Secret carries the expected labels.
- Secret type is `Opaque`.

### `serviceaccount_test.yaml` (~4 tests)

- `create = true` (default) → ServiceAccount rendered with auto-name and
  `automountServiceAccountToken: false`.
- `create = false` → not rendered.
- Custom `serviceAccount.name` honored.
- `serviceAccount.annotations` flow through.

### `notes_test.yaml` (~3 tests)

- Default render: NOTES.txt contains expected guidance text.
- HA-mode render: NOTES.txt contains HA-specific guidance.
- HPA-enabled render: NOTES.txt mentions autoscaling.

(Exact strings to be confirmed against the current `NOTES.txt` content during
implementation.)

### `helpers_test.yaml` (~6 tests)

Asserts helper outputs via the StatefulSet template (helm-unittest cannot
render `_helpers.tpl` directly).

- `arcadedb.nodenames` produces the expected comma-separated FQDN list at
  `replicaCount = 3`.
- `arcadedb.nodenames` sizes to `autoscaling.maxReplicas` when HPA is
  enabled and `maxReplicas > replicaCount`.
- `arcadedb.k8sSuffix` format: `.<fullname>.<namespace>.svc.cluster.local`.
- `arcadedb.fullname` truncation to 63 chars works with long release names.
- `fullnameOverride` wins over the auto-derived fullname.
- `arcadedb.plugin.parameters` ordering is deterministic across renders
  (helps prevent diff churn in PRs).

### `extra_manifests_test.yaml` (~3 tests)

- Empty default → no extra manifests rendered.
- Populated map → each entry renders as its own document.
- Templating inside extra manifests works (release name interpolation, etc.).

## CI Restructure

`.github/workflows/lint.yml` is split into three parallel jobs. The file name
stays `lint.yml` to avoid churning branch protection rules.

```yaml
name: Lint

on:
  push: { branches: [main] }
  pull_request: { branches: [main] }

permissions:
  contents: read

jobs:
  lint:
    runs-on: ubuntu-24.04
    steps:
      - uses: actions/checkout@<sha>
      - uses: azure/setup-helm@<sha>
        with: { version: v3.14.0 }
      - run: make lint

  unittest:
    runs-on: ubuntu-24.04
    steps:
      - uses: actions/checkout@<sha>
      - uses: azure/setup-helm@<sha>
        with: { version: v3.14.0 }
      - run: make test-unit

  integration:
    runs-on: ubuntu-24.04
    timeout-minutes: 20
    steps:
      - uses: actions/checkout@<sha>
      - name: Install kind
        run: |
          curl -sLo /tmp/kind-linux-amd64 https://kind.sigs.k8s.io/dl/v0.23.0/kind-linux-amd64
          curl -sLo /tmp/kind.sha256 https://kind.sigs.k8s.io/dl/v0.23.0/kind-linux-amd64.sha256sum
          (cd /tmp && sha256sum -c kind.sha256)
          install -m 0755 /tmp/kind-linux-amd64 /usr/local/bin/kind
      - name: Install kubectl
        run: |
          curl -sLo /tmp/kubectl "https://dl.k8s.io/release/v1.30.0/bin/linux/amd64/kubectl"
          curl -sLo /tmp/kubectl.sha256 "https://dl.k8s.io/release/v1.30.0/bin/linux/amd64/kubectl.sha256"
          echo "$(cat /tmp/kubectl.sha256)  /tmp/kubectl" | sha256sum -c -
          install -m 0755 /tmp/kubectl /usr/local/bin/kubectl
      - uses: azure/setup-helm@<sha>
        with: { version: v3.14.0 }
      - name: Create kind cluster
        run: kind create cluster --wait 60s
      - name: Install chart
        run: |
          helm install test-arcadedb charts/arcadedb/ \
            --set replicaCount=3 \
            --set image.tag=latest \
            --set persistence.enabled=false \
            --set arcadedb.defaultDatabases="" \
            --timeout 5m --wait
      - name: Run integration tests
        run: make test-integration
      - name: Delete kind cluster
        if: always()
        run: kind delete cluster
```

The current action SHAs in `lint.yml` are preserved; `<sha>` is a placeholder
in this design only.

Removed from the existing workflow:
- The six `helm template` smoke-render steps.
- The `helm template … | grep -q "kind: HorizontalPodAutoscaler"` positive check.
- The bash incantation asserting the quorum-guard fail.

All three are subsumed by the `unittest` job.

## Makefile

```makefile
HELM ?= helm
CHART_DIR := charts/arcadedb
HELM_UNITTEST_VERSION := 0.5.2

.PHONY: help lint test-unit test-integration test plugin-install

help:
	@echo "Targets:"
	@echo "  make lint              Run helm lint"
	@echo "  make test-unit         Run helm-unittest suites"
	@echo "  make test-integration  Run kind-based integration tests"
	@echo "  make test              All of the above"
	@echo "  make plugin-install    (Re)install helm-unittest plugin at pinned version"

lint:
	$(HELM) lint $(CHART_DIR)

# Idempotent: install or reinstall helm-unittest only if missing or version-mismatched.
plugin-install:
	@current=$$($(HELM) plugin list 2>/dev/null | awk '$$1=="unittest"{print $$2}'); \
	if [ "$$current" != "$(HELM_UNITTEST_VERSION)" ]; then \
	  $(HELM) plugin uninstall unittest 2>/dev/null || true; \
	  $(HELM) plugin install https://github.com/helm-unittest/helm-unittest --version $(HELM_UNITTEST_VERSION); \
	fi

test-unit: plugin-install
	$(HELM) unittest $(CHART_DIR)

test-integration:
	bash ci/integration-test.sh

test: lint test-unit test-integration
```

`HELM_UNITTEST_VERSION` is the single source of truth — change it in one
place, CI and contributors get the same version. `plugin-install` is a
prerequisite of `test-unit`, so `make test-unit` works on a clean machine
without manual setup.

## README Update

Add a short "Development" section pointing contributors at `make help`. Keep
it minimal — the Makefile is self-documenting.

## Out of Scope / Risks

- **helm-unittest version drift.** Pinned in the Makefile; CI uses the same
  Makefile target, so drift is unlikely. Monitor releases manually for now.
- **`_helpers.tpl` direct testing.** helm-unittest cannot render
  `_helpers.tpl` standalone. Helper assertions are made through consuming
  templates (typically `statefulset.yaml`); this is acceptable but means a
  helper bug only surfaces when its consumer's tests cover the relevant
  branch. The `helpers_test.yaml` suite is designed to cover the important
  branches explicitly.
- **`_helpers.tpl` and `_arcadedb.plugin.ports`.** The plugin parameter
  generation is non-trivial (line 96–156 of `_helpers.tpl`). The plugin
  branch in `statefulset_test.yaml` covers each plugin type; a regression in
  the helper would surface as a plugin-flag assertion failure.
- **Branch protection.** Job names change (`lint` job stays, `unittest` and
  `integration` are added/renamed). If branch protection requires named
  status checks, those need to be updated in repo settings — out of scope for
  this design but a note for whoever lands the PR.

## Implementation Order (high-level)

The detailed implementation plan will be authored separately by the
writing-plans skill. At a high level:

1. Add `Makefile` and `.helmignore` change; verify `make lint` works locally.
2. Add `plugin-install` target and verify `make test-unit` works against an
   empty `tests/` directory (should succeed with zero suites).
3. Author test suites incrementally, running `make test-unit` after each.
   Recommended order: `serviceaccount` → `secret` → `service` → `ingress` →
   `networkpolicy` → `hpa` → `quorum_guard` → `notes` → `extra_manifests` →
   `helpers` → `statefulset` (largest last).
4. Restructure `.github/workflows/lint.yml` once all suites pass locally.
5. Update `README.md` with the "Development" section.
6. Confirm CI green on PR.
