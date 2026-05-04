# Helm Unittest Migration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace ad-hoc `helm template … | grep` checks in CI with full-coverage [helm-unittest](https://github.com/helm-unittest/helm-unittest) suites; add a Makefile entry point; restructure CI into `lint` / `unittest` / `integration` jobs.

**Architecture:** New `charts/arcadedb/tests/` directory holds one suite per template plus a cross-cutting `quorum_guard_test.yaml`. Tests are excluded from the packaged tarball via `.helmignore`. A new top-level `Makefile` is the single entry point for `lint`, `test-unit`, and `test-integration` — used by both contributors and CI. Template assertions are explicit (no snapshots).

**Tech Stack:** Helm v3.14, helm-unittest plugin v0.5.2 (pinned in Makefile), GNU Make, GitHub Actions.

---

## Pre-Read

Before starting, read these to ground yourself in current state:

- `charts/arcadedb/Chart.yaml` — chart name `arcadedb`, version `26.4.2`.
- `charts/arcadedb/values.yaml` — all defaults referenced in tests come from here.
- `charts/arcadedb/templates/_helpers.tpl` — `arcadedb.fullname`, `arcadedb.nodenames`, `arcadedb.k8sSuffix`, `arcadedb.plugin.parameters`, `arcadedb.plugin.service`, `arcadedb.serviceAccountName`.
- `charts/arcadedb/templates/statefulset.yaml` — the largest template; many tests render through it.
- `.github/workflows/lint.yml` — current CI; you'll restructure this.
- `docs/superpowers/specs/2026-05-04-helm-unittest-migration-design.md` — the approved design.

## Conventions Used Throughout

- Every test suite uses `release: { name: test, namespace: default }` so `arcadedb.fullname` resolves to `test-arcadedb` and `arcadedb.k8sSuffix` resolves to `.test-arcadedb.default.svc.cluster.local`.
- The chart name is `arcadedb`. With release name `test`, since `test` does NOT contain `arcadedb`, fullname follows the `printf "%s-%s" .Release.Name $name` branch → `test-arcadedb`.
- All commands assume the working directory is the repo root.
- `helm unittest` exit code is non-zero on any failure. Steps that say "Expected: PASS" mean exit 0 and "X passed, 0 failed" in the summary.

## File Structure

**Created:**
- `Makefile` — one entry point per check kind.
- `charts/arcadedb/.helmignore` — excludes `tests/` from packaged tarball.
- `charts/arcadedb/tests/serviceaccount_test.yaml`
- `charts/arcadedb/tests/secret_test.yaml`
- `charts/arcadedb/tests/service_test.yaml`
- `charts/arcadedb/tests/ingress_test.yaml`
- `charts/arcadedb/tests/networkpolicy_test.yaml`
- `charts/arcadedb/tests/hpa_test.yaml`
- `charts/arcadedb/tests/quorum_guard_test.yaml`
- `charts/arcadedb/tests/notes_test.yaml`
- `charts/arcadedb/tests/extra_manifests_test.yaml`
- `charts/arcadedb/tests/helpers_test.yaml`
- `charts/arcadedb/tests/statefulset_test.yaml`

**Modified:**
- `.github/workflows/lint.yml` — split into three jobs.
- `README.md` — add a brief "Development" section.

**Order of implementation:** small/independent suites first, statefulset last. This builds confidence with the tooling before tackling the most complex template.

---

## Task 1: Add Makefile and verify `helm lint`

**Files:**
- Create: `Makefile`

- [ ] **Step 1: Create the Makefile**

Create `Makefile`:

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

- [ ] **Step 2: Verify `make lint` works**

Run: `make lint`
Expected: same output as `helm lint charts/arcadedb/` — `1 chart(s) linted, 0 chart(s) failed`.

- [ ] **Step 3: Verify `make help` works**

Run: `make help`
Expected: prints the target list shown in `help:`.

- [ ] **Step 4: Commit**

```bash
git add Makefile
git commit -m "build: add Makefile with lint, test-unit, test-integration targets"
```

---

## Task 2: Add `.helmignore` to exclude `tests/` from package

**Files:**
- Create: `charts/arcadedb/.helmignore`

- [ ] **Step 1: Create the `.helmignore`**

Create `charts/arcadedb/.helmignore`:

```
# Patterns to ignore when packaging Helm charts.
# These files won't be added to the chart tarball.

# OS files
.DS_Store

# Version control
.git/
.gitignore
.bzr/
.hg/
.hgignore
.svn/

# IDE
.idea/
.project
.vscode/

# Backup / temp
*.swp
*.tmp
*.orig
*.bak
*~

# helm-unittest test suites — not part of the published chart
tests/
```

- [ ] **Step 2: Verify `helm package` excludes `tests/`**

Even though `tests/` doesn't exist yet, verify the ignore file is honored by running:

```bash
mkdir -p charts/arcadedb/tests
echo "should-not-be-packaged" > charts/arcadedb/tests/_probe.yaml
helm package charts/arcadedb -d /tmp/
tar tzf /tmp/arcadedb-26.4.2.tgz | grep tests/ && echo "FAIL: tests/ included" || echo "OK: tests/ excluded"
rm /tmp/arcadedb-26.4.2.tgz
rm charts/arcadedb/tests/_probe.yaml
rmdir charts/arcadedb/tests
```

Expected: `OK: tests/ excluded`.

- [ ] **Step 3: Commit**

```bash
git add charts/arcadedb/.helmignore
git commit -m "build: add .helmignore excluding tests/ from packaged chart"
```

---

## Task 3: Verify `make test-unit` installs plugin and runs against empty `tests/`

**Files:**
- Create: `charts/arcadedb/tests/` (empty directory; helm-unittest needs the dir to exist)

- [ ] **Step 1: Create the empty tests directory**

Run:
```bash
mkdir -p charts/arcadedb/tests
touch charts/arcadedb/tests/.gitkeep
```

- [ ] **Step 2: Run `make test-unit`**

Run: `make test-unit`
Expected: helm-unittest plugin installs (or already at 0.5.2), then runs with output similar to `### Chart [ arcadedb ]` and `Charts: 0 passed, 0 failed`. Exit code 0. (helm-unittest treats "no test files" as success.)

If you see `Error: plugin "unittest" exited with error`, the plugin install failed — check internet access and re-run.

- [ ] **Step 3: Commit**

```bash
git add charts/arcadedb/tests/.gitkeep
git commit -m "build: scaffold helm-unittest tests directory"
```

---

## Task 4: ServiceAccount suite

**Files:**
- Create: `charts/arcadedb/tests/serviceaccount_test.yaml`

The `serviceaccount.yaml` template renders only when `serviceAccount.create: true` (default). Name follows `arcadedb.serviceAccountName`: defaults to `arcadedb.fullname` (= `test-arcadedb` here), but uses `serviceAccount.name` when set.

- [ ] **Step 1: Write the suite**

Create `charts/arcadedb/tests/serviceaccount_test.yaml`:

```yaml
suite: ServiceAccount
templates:
  - serviceaccount.yaml
release:
  name: test
  namespace: default
tests:
  - it: renders by default with auto-generated name
    asserts:
      - hasDocuments: { count: 1 }
      - isKind: { of: ServiceAccount }
      - equal: { path: metadata.name, value: test-arcadedb }
      - equal: { path: automountServiceAccountToken, value: false }

  - it: is not rendered when serviceAccount.create is false
    set:
      serviceAccount.create: false
    asserts:
      - hasDocuments: { count: 0 }

  - it: honors a custom serviceAccount.name
    set:
      serviceAccount.name: my-sa
    asserts:
      - equal: { path: metadata.name, value: my-sa }

  - it: flows annotations through
    set:
      serviceAccount.annotations:
        eks.amazonaws.com/role-arn: arn:aws:iam::123:role/my-role
    asserts:
      - equal:
          path: metadata.annotations["eks.amazonaws.com/role-arn"]
          value: arn:aws:iam::123:role/my-role

  - it: enables token automount when serviceAccount.automount is true
    set:
      serviceAccount.automount: true
    asserts:
      - equal: { path: automountServiceAccountToken, value: true }
```

- [ ] **Step 2: Run the suite**

Run: `make test-unit`
Expected: `Test Suites: 1 passed, 1 total` and `Tests: 5 passed, 5 total`. Exit 0.

If any test fails, read the failure message — most failures here will be path or value typos. Do not change the chart templates to make tests pass; the chart is the source of truth.

- [ ] **Step 3: Commit**

```bash
git add charts/arcadedb/tests/serviceaccount_test.yaml
git rm charts/arcadedb/tests/.gitkeep
git commit -m "test: add helm-unittest ServiceAccount suite"
```

---

## Task 5: Secret suite

**Files:**
- Create: `charts/arcadedb/tests/secret_test.yaml`

The `secret.yaml` template renders only when `arcadedb.credentials.rootPassword.secret.name` is empty/null (the default). It uses `lookup` for idempotency, but in a unit-test context `lookup` returns nil/empty, so a new random password is generated each render. The Secret name is hard-coded `arcadedb-credentials-secret`.

- [ ] **Step 1: Write the suite**

Create `charts/arcadedb/tests/secret_test.yaml`:

```yaml
suite: Credentials Secret
templates:
  - secret.yaml
release:
  name: test
  namespace: default
tests:
  - it: renders the auto-generated credentials secret by default
    asserts:
      - hasDocuments: { count: 1 }
      - isKind: { of: Secret }
      - equal: { path: metadata.name, value: arcadedb-credentials-secret }
      - equal: { path: type, value: Opaque }
      - exists: { path: data.rootPassword }

  - it: rootPassword is base64-encoded (32 chars random → 44 base64 chars including padding)
    asserts:
      - matchRegex:
          path: data.rootPassword
          pattern: "^[A-Za-z0-9+/]{43}=$"

  - it: is not rendered when an existing secret name is supplied
    set:
      arcadedb.credentials.rootPassword.secret.name: my-existing-secret
      arcadedb.credentials.rootPassword.secret.key: rootPassword
    asserts:
      - hasDocuments: { count: 0 }
```

- [ ] **Step 2: Run the suite**

Run: `make test-unit`
Expected: `Test Suites: 2 passed, 2 total`, `Tests: 8 passed, 8 total`.

- [ ] **Step 3: Commit**

```bash
git add charts/arcadedb/tests/secret_test.yaml
git commit -m "test: add helm-unittest Secret suite"
```

---

## Task 6: Service suite

**Files:**
- Create: `charts/arcadedb/tests/service_test.yaml`

`service.yaml` always renders TWO documents: a `*-http` Service (default ClusterIP) and a headless service (`fullname` only) used for StatefulSet pod DNS. The headless service includes the http port, rpc port, AND any plugin ports projected via `arcadedb.plugin.service`. Use `documentIndex: 0` for the http service and `documentIndex: 1` for the headless service.

- [ ] **Step 1: Write the suite**

Create `charts/arcadedb/tests/service_test.yaml`:

```yaml
suite: Service
templates:
  - service.yaml
release:
  name: test
  namespace: default
tests:
  - it: renders two services by default (client + headless)
    asserts:
      - hasDocuments: { count: 2 }

  - it: client service has correct name, type, and http port
    documentIndex: 0
    asserts:
      - isKind: { of: Service }
      - equal: { path: metadata.name, value: test-arcadedb-http }
      - equal: { path: spec.type, value: ClusterIP }
      - contains:
          path: spec.ports
          content:
            port: 2480
            targetPort: http
            protocol: TCP
            name: http
      - equal: { path: spec.selector["app.kubernetes.io/name"], value: arcadedb }
      - equal: { path: spec.selector["app.kubernetes.io/instance"], value: test }

  - it: client service type can be overridden to LoadBalancer
    set:
      service.http.type: LoadBalancer
    documentIndex: 0
    asserts:
      - equal: { path: spec.type, value: LoadBalancer }

  - it: client service http port can be overridden
    set:
      service.http.port: 8080
    documentIndex: 0
    asserts:
      - contains:
          path: spec.ports
          content:
            port: 8080
            targetPort: http
            protocol: TCP
            name: http

  - it: headless service is named after the chart fullname and has clusterIP None
    documentIndex: 1
    asserts:
      - isKind: { of: Service }
      - equal: { path: metadata.name, value: test-arcadedb }
      - equal: { path: spec.clusterIP, value: None }
      - equal: { path: spec.publishNotReadyAddresses, value: true }

  - it: headless service exposes both http and rpc ports by default
    documentIndex: 1
    asserts:
      - contains:
          path: spec.ports
          content: { port: 2480, targetPort: http, protocol: TCP, name: http }
      - contains:
          path: spec.ports
          content: { port: 2434, targetPort: rpc, protocol: TCP, name: rpc }

  - it: headless service rpc port can be overridden
    set:
      service.rpc.port: 5000
    documentIndex: 1
    asserts:
      - contains:
          path: spec.ports
          content: { port: 5000, targetPort: rpc, protocol: TCP, name: rpc }

  - it: headless service exposes gremlin plugin port when enabled
    set:
      arcadedb.plugins.gremlin.enabled: true
      arcadedb.plugins.gremlin.port: 8182
    documentIndex: 1
    asserts:
      - contains:
          path: spec.ports
          content: { port: 8182, targetPort: 8182, protocol: TCP, name: gremlin-port }

  - it: headless service exposes postgres plugin port when enabled
    set:
      arcadedb.plugins.postgres.enabled: true
      arcadedb.plugins.postgres.port: 5432
    documentIndex: 1
    asserts:
      - contains:
          path: spec.ports
          content: { port: 5432, targetPort: 5432, protocol: TCP, name: postgres-port }

  - it: headless service exposes mongo plugin port when enabled
    set:
      arcadedb.plugins.mongo.enabled: true
      arcadedb.plugins.mongo.port: 27017
    documentIndex: 1
    asserts:
      - contains:
          path: spec.ports
          content: { port: 27017, targetPort: 27017, protocol: TCP, name: mongo-port }

  - it: headless service exposes redis plugin port when enabled
    set:
      arcadedb.plugins.redis.enabled: true
      arcadedb.plugins.redis.port: 6379
    documentIndex: 1
    asserts:
      - contains:
          path: spec.ports
          content: { port: 6379, targetPort: 6379, protocol: TCP, name: redis-port }

  - it: prometheus plugin does not add a service port (port = -1 sentinel)
    set:
      arcadedb.plugins.prometheus.enabled: true
    documentIndex: 1
    asserts:
      - notContains:
          path: spec.ports
          content: { name: prometheus-port }

  - it: custom plugin with port adds a service port
    set:
      arcadedb.plugins.myplugin.enabled: true
      arcadedb.plugins.myplugin.port: 1234
      arcadedb.plugins.myplugin.class: com.example.MyPlugin
    documentIndex: 1
    asserts:
      - contains:
          path: spec.ports
          content: { port: 1234, targetPort: 1234, protocol: TCP, name: myplugin-port }

  - it: headless service selector matches StatefulSet selector
    documentIndex: 1
    asserts:
      - equal: { path: spec.selector["app.kubernetes.io/name"], value: arcadedb }
      - equal: { path: spec.selector["app.kubernetes.io/instance"], value: test }
```

- [ ] **Step 2: Run the suite**

Run: `make test-unit`
Expected: all suites pass; Service suite reports 14 tests.

- [ ] **Step 3: Commit**

```bash
git add charts/arcadedb/tests/service_test.yaml
git commit -m "test: add helm-unittest Service suite"
```

---

## Task 7: Ingress suite

**Files:**
- Create: `charts/arcadedb/tests/ingress_test.yaml`

`ingress.yaml` only renders when `ingress.enabled: true`.

- [ ] **Step 1: Write the suite**

Create `charts/arcadedb/tests/ingress_test.yaml`:

```yaml
suite: Ingress
templates:
  - ingress.yaml
release:
  name: test
  namespace: default
tests:
  - it: is not rendered by default
    asserts:
      - hasDocuments: { count: 0 }

  - it: renders with default host and path when enabled
    set:
      ingress.enabled: true
    asserts:
      - hasDocuments: { count: 1 }
      - isKind: { of: Ingress }
      - equal: { path: metadata.name, value: test-arcadedb }
      - equal: { path: spec.rules[0].host, value: chart-example.local }
      - equal: { path: spec.rules[0].http.paths[0].path, value: / }
      - equal: { path: spec.rules[0].http.paths[0].pathType, value: ImplementationSpecific }
      - equal: { path: spec.rules[0].http.paths[0].backend.service.name, value: test-arcadedb-http }
      - equal: { path: spec.rules[0].http.paths[0].backend.service.port.number, value: 2480 }

  - it: honors className when set
    set:
      ingress.enabled: true
      ingress.className: nginx
    asserts:
      - equal: { path: spec.ingressClassName, value: nginx }

  - it: omits ingressClassName when className is empty
    set:
      ingress.enabled: true
    asserts:
      - notExists: { path: spec.ingressClassName }

  - it: flows annotations through
    set:
      ingress.enabled: true
      ingress.annotations:
        kubernetes.io/ingress.class: nginx
        cert-manager.io/cluster-issuer: letsencrypt
    asserts:
      - equal:
          path: metadata.annotations["kubernetes.io/ingress.class"]
          value: nginx
      - equal:
          path: metadata.annotations["cert-manager.io/cluster-issuer"]
          value: letsencrypt

  - it: renders TLS configuration when set
    set:
      ingress.enabled: true
      ingress.tls:
        - secretName: my-tls
          hosts:
            - chart-example.local
    asserts:
      - equal: { path: spec.tls[0].secretName, value: my-tls }
      - equal: { path: spec.tls[0].hosts[0], value: chart-example.local }

  - it: renders multiple hosts and paths
    set:
      ingress.enabled: true
      ingress.hosts:
        - host: a.example.com
          paths:
            - path: /
              pathType: Prefix
        - host: b.example.com
          paths:
            - path: /api
              pathType: Prefix
            - path: /studio
              pathType: Exact
    asserts:
      - equal: { path: spec.rules[0].host, value: a.example.com }
      - equal: { path: spec.rules[1].host, value: b.example.com }
      - equal: { path: spec.rules[1].http.paths[0].path, value: /api }
      - equal: { path: spec.rules[1].http.paths[1].path, value: /studio }
      - equal: { path: spec.rules[1].http.paths[1].pathType, value: Exact }

  - it: backend service.port.number reflects custom service.http.port
    set:
      ingress.enabled: true
      service.http.port: 9090
    asserts:
      - equal: { path: spec.rules[0].http.paths[0].backend.service.port.number, value: 9090 }
```

- [ ] **Step 2: Run the suite**

Run: `make test-unit`
Expected: all suites pass; Ingress suite reports 8 tests.

- [ ] **Step 3: Commit**

```bash
git add charts/arcadedb/tests/ingress_test.yaml
git commit -m "test: add helm-unittest Ingress suite"
```

---

## Task 8: NetworkPolicy suite

**Files:**
- Create: `charts/arcadedb/tests/networkpolicy_test.yaml`

`networkpolicy.yaml` renders TWO documents when `networkPolicy.enabled: true`: an `*-http` policy (HTTP open to all cluster pods) and an `*-raft` policy (RPC restricted to ArcadeDB pods).

- [ ] **Step 1: Write the suite**

Create `charts/arcadedb/tests/networkpolicy_test.yaml`:

```yaml
suite: NetworkPolicy
templates:
  - networkpolicy.yaml
release:
  name: test
  namespace: default
tests:
  - it: is not rendered by default
    asserts:
      - hasDocuments: { count: 0 }

  - it: renders two NetworkPolicies when enabled
    set:
      networkPolicy.enabled: true
    asserts:
      - hasDocuments: { count: 2 }

  - it: http policy has correct name and selector
    set:
      networkPolicy.enabled: true
    documentIndex: 0
    asserts:
      - isKind: { of: NetworkPolicy }
      - equal: { path: metadata.name, value: test-arcadedb-http }
      - equal: { path: spec.podSelector.matchLabels["app.kubernetes.io/name"], value: arcadedb }
      - equal: { path: spec.podSelector.matchLabels["app.kubernetes.io/instance"], value: test }

  - it: http policy allows ingress on port 2480 from any source (no `from`)
    set:
      networkPolicy.enabled: true
    documentIndex: 0
    asserts:
      - equal: { path: spec.ingress[0].ports[0].port, value: 2480 }
      - equal: { path: spec.ingress[0].ports[0].protocol, value: TCP }
      - notExists: { path: spec.ingress[0].from }

  - it: raft policy has correct name and restricts to ArcadeDB pods
    set:
      networkPolicy.enabled: true
    documentIndex: 1
    asserts:
      - isKind: { of: NetworkPolicy }
      - equal: { path: metadata.name, value: test-arcadedb-raft }
      - equal:
          path: spec.ingress[0].from[0].podSelector.matchLabels["app.kubernetes.io/name"]
          value: arcadedb
      - equal:
          path: spec.ingress[0].from[0].podSelector.matchLabels["app.kubernetes.io/instance"]
          value: test
      - equal: { path: spec.ingress[0].ports[0].port, value: 2434 }
      - equal: { path: spec.ingress[0].ports[0].protocol, value: TCP }

  - it: http policy port reflects custom service.http.port
    set:
      networkPolicy.enabled: true
      service.http.port: 9090
    documentIndex: 0
    asserts:
      - equal: { path: spec.ingress[0].ports[0].port, value: 9090 }

  - it: raft policy port reflects custom service.rpc.port
    set:
      networkPolicy.enabled: true
      service.rpc.port: 5555
    documentIndex: 1
    asserts:
      - equal: { path: spec.ingress[0].ports[0].port, value: 5555 }
```

- [ ] **Step 2: Run the suite**

Run: `make test-unit`
Expected: all suites pass; NetworkPolicy suite reports 7 tests.

- [ ] **Step 3: Commit**

```bash
git add charts/arcadedb/tests/networkpolicy_test.yaml
git commit -m "test: add helm-unittest NetworkPolicy suite"
```

---

## Task 9: HPA suite

**Files:**
- Create: `charts/arcadedb/tests/hpa_test.yaml`

`hpa.yaml` renders only when `autoscaling.enabled: true`. The default `autoscaling.minReplicas: 1` violates the quorum guard with default `maxReplicas: 5` (needs `>= 3`), so any test that enables autoscaling without bumping `minReplicas` to a quorum-safe value will hit the `fail` — those go in `quorum_guard_test.yaml` (next task). This suite only covers the success branch.

- [ ] **Step 1: Write the suite**

Create `charts/arcadedb/tests/hpa_test.yaml`:

```yaml
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
      - equal: { path: metadata.name, value: test-arcadedb }
      - equal: { path: spec.minReplicas, value: 3 }
      - equal: { path: spec.maxReplicas, value: 5 }
      - equal: { path: spec.scaleTargetRef.apiVersion, value: apps/v1 }
      - equal: { path: spec.scaleTargetRef.kind, value: StatefulSet }
      - equal: { path: spec.scaleTargetRef.name, value: test-arcadedb }

  - it: includes CPU metric by default (targetCPUUtilizationPercentage=80 in values.yaml)
    set:
      autoscaling.enabled: true
      autoscaling.minReplicas: 3
      autoscaling.maxReplicas: 5
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

  - it: omits CPU metric when targetCPUUtilizationPercentage is null
    set:
      autoscaling.enabled: true
      autoscaling.minReplicas: 3
      autoscaling.maxReplicas: 5
      autoscaling.targetCPUUtilizationPercentage: null
    asserts:
      - notContains:
          path: spec.metrics
          content:
            type: Resource
            resource: { name: cpu, target: { type: Utilization, averageUtilization: 80 } }

  - it: includes memory metric when targetMemoryUtilizationPercentage is set
    set:
      autoscaling.enabled: true
      autoscaling.minReplicas: 3
      autoscaling.maxReplicas: 5
      autoscaling.targetMemoryUtilizationPercentage: 75
    asserts:
      - contains:
          path: spec.metrics
          content:
            type: Resource
            resource:
              name: memory
              target:
                type: Utilization
                averageUtilization: 75

  - it: omits memory metric by default
    set:
      autoscaling.enabled: true
      autoscaling.minReplicas: 3
      autoscaling.maxReplicas: 5
    asserts:
      - notContains:
          path: spec.metrics
          content: { type: Resource, resource: { name: memory } }

  - it: respects custom min/max
    set:
      autoscaling.enabled: true
      autoscaling.minReplicas: 4
      autoscaling.maxReplicas: 7
    asserts:
      - equal: { path: spec.minReplicas, value: 4 }
      - equal: { path: spec.maxReplicas, value: 7 }
```

- [ ] **Step 2: Run the suite**

Run: `make test-unit`
Expected: all suites pass; HPA suite reports 7 tests.

- [ ] **Step 3: Commit**

```bash
git add charts/arcadedb/tests/hpa_test.yaml
git commit -m "test: add helm-unittest HPA suite"
```

---

## Task 10: Quorum guard / fail-assertion suite

**Files:**
- Create: `charts/arcadedb/tests/quorum_guard_test.yaml`

This suite covers `fail`-based invariants. Two distinct sources of failures:

1. **HPA quorum guard** (`hpa.yaml` lines 5-8): `minReplicas` must be `>= floor(maxReplicas/2)+1`. Asserted against `hpa.yaml`.
2. **Custom plugin missing port** (`_helpers.tpl` lines 113-115): a non-built-in plugin without a `port` triggers `fail`. The helper is consumed by `statefulset.yaml`, so the assertion is made there.

`failedTemplate.errorMessage` is matched as a substring (helm-unittest 0.5.x). Use the distinctive part of the message.

- [ ] **Step 1: Write the suite**

Create `charts/arcadedb/tests/quorum_guard_test.yaml`:

```yaml
suite: Quorum guard and helper fail-assertions
release:
  name: test
  namespace: default
tests:
  - it: HPA fails when minReplicas=1 violates quorum (maxReplicas=5 needs >=3)
    templates:
      - hpa.yaml
    set:
      autoscaling.enabled: true
      autoscaling.minReplicas: 1
      autoscaling.maxReplicas: 5
    asserts:
      - failedTemplate:
          errorMessage: "autoscaling.minReplicas (1) must be >= floor(maxReplicas/2)+1 (3) to maintain Raft quorum with maxReplicas=5"

  - it: HPA fails just below boundary (minReplicas=2, maxReplicas=5 needs >=3)
    templates:
      - hpa.yaml
    set:
      autoscaling.enabled: true
      autoscaling.minReplicas: 2
      autoscaling.maxReplicas: 5
    asserts:
      - failedTemplate:
          errorMessage: "autoscaling.minReplicas (2) must be >= floor(maxReplicas/2)+1 (3)"

  - it: HPA renders at lower quorum boundary (minReplicas=3, maxReplicas=5)
    templates:
      - hpa.yaml
    set:
      autoscaling.enabled: true
      autoscaling.minReplicas: 3
      autoscaling.maxReplicas: 5
    asserts:
      - hasDocuments: { count: 1 }

  - it: HPA renders at boundary for maxReplicas=3 (needs >=2)
    templates:
      - hpa.yaml
    set:
      autoscaling.enabled: true
      autoscaling.minReplicas: 2
      autoscaling.maxReplicas: 3
    asserts:
      - hasDocuments: { count: 1 }

  - it: custom plugin without port fails with "no port specified"
    templates:
      - statefulset.yaml
    set:
      arcadedb.plugins.myplugin.enabled: true
      arcadedb.plugins.myplugin.class: com.example.MyPlugin
    asserts:
      - failedTemplate:
          errorMessage: "Custom plugin 'myplugin' has no port specified"
```

- [ ] **Step 2: Run the suite**

Run: `make test-unit`
Expected: all suites pass; Quorum suite reports 5 tests.

- [ ] **Step 3: Commit**

```bash
git add charts/arcadedb/tests/quorum_guard_test.yaml
git commit -m "test: add helm-unittest quorum guard and helper-fail suite"
```

---

## Task 11: NOTES.txt suite

**Files:**
- Create: `charts/arcadedb/tests/notes_test.yaml`

helm-unittest renders NOTES.txt as a single document under `templates: [NOTES.txt]`. Assertions go against `path: ""` matching the entire rendered text via `matchRegex`.

- [ ] **Step 1: Write the suite**

Create `charts/arcadedb/tests/notes_test.yaml`:

```yaml
suite: NOTES.txt
templates:
  - NOTES.txt
release:
  name: test
  namespace: default
tests:
  - it: includes the application URL preamble
    asserts:
      - matchRegex:
          path: ""
          pattern: "Get the application URL"

  - it: shows port-forward instructions for default ClusterIP service type
    asserts:
      - matchRegex:
          path: ""
          pattern: "kubectl --namespace default port-forward"

  - it: shows ingress URLs when ingress is enabled
    set:
      ingress.enabled: true
    asserts:
      - matchRegex:
          path: ""
          pattern: "http://chart-example.local/"

  - it: shows https URL when ingress TLS is configured
    set:
      ingress.enabled: true
      ingress.tls:
        - secretName: my-tls
          hosts: [chart-example.local]
    asserts:
      - matchRegex:
          path: ""
          pattern: "https://chart-example.local/"

  - it: warns about ephemeral data when persistence is disabled
    set:
      persistence.enabled: false
    asserts:
      - matchRegex:
          path: ""
          pattern: "WARNING: persistence.enabled is false"

  - it: does not warn when persistence is enabled (default)
    asserts:
      - notMatchRegex:
          path: ""
          pattern: "WARNING: persistence.enabled is false"
```

- [ ] **Step 2: Run the suite**

Run: `make test-unit`
Expected: all suites pass; NOTES suite reports 6 tests.

If `path: ""` doesn't match the rendered text in your version of helm-unittest, try `path: "$"` instead. The convention for plain-text templates differs slightly across plugin versions; v0.5.x supports `path: ""`.

- [ ] **Step 3: Commit**

```bash
git add charts/arcadedb/tests/notes_test.yaml
git commit -m "test: add helm-unittest NOTES.txt suite"
```

---

## Task 12: Extra manifests suite

**Files:**
- Create: `charts/arcadedb/tests/extra_manifests_test.yaml`

`extra-manifests.yaml` iterates over `.Values.extraManifests` (a map) and renders each value as a separate document.

- [ ] **Step 1: Write the suite**

Create `charts/arcadedb/tests/extra_manifests_test.yaml`:

```yaml
suite: Extra manifests
templates:
  - extra-manifests.yaml
release:
  name: test
  namespace: default
tests:
  - it: renders nothing by default
    asserts:
      - hasDocuments: { count: 0 }

  - it: renders a single ConfigMap from extraManifests
    set:
      extraManifests:
        myConfigMap:
          apiVersion: v1
          kind: ConfigMap
          metadata:
            name: my-config
          data:
            key: value
    asserts:
      - hasDocuments: { count: 1 }
      - isKind: { of: ConfigMap }
      - equal: { path: metadata.name, value: my-config }
      - equal: { path: data.key, value: value }

  - it: renders multiple manifests as separate documents
    set:
      extraManifests:
        cm:
          apiVersion: v1
          kind: ConfigMap
          metadata: { name: cm1 }
        secret:
          apiVersion: v1
          kind: Secret
          metadata: { name: secret1 }
          type: Opaque
    asserts:
      - hasDocuments: { count: 2 }
```

- [ ] **Step 2: Run the suite**

Run: `make test-unit`
Expected: all suites pass; Extra manifests suite reports 3 tests.

- [ ] **Step 3: Commit**

```bash
git add charts/arcadedb/tests/extra_manifests_test.yaml
git commit -m "test: add helm-unittest extra manifests suite"
```

---

## Task 13: Helpers suite

**Files:**
- Create: `charts/arcadedb/tests/helpers_test.yaml`

Helpers in `_helpers.tpl` cannot be rendered standalone by helm-unittest. Assert their output by examining the StatefulSet, where most are consumed.

Key helpers under test:
- `arcadedb.fullname` — naming, truncation, override.
- `arcadedb.k8sSuffix` — appears in `-Darcadedb.ha.k8sSuffix=` command flag when HA is on.
- `arcadedb.nodenames` — appears in `-Darcadedb.ha.serverList=` flag; sized to `replicaCount` or `autoscaling.maxReplicas` (whichever is larger when HPA is enabled).
- `arcadedb.plugin.parameters` — emits `-Darcadedb.server.plugins=` and per-plugin port flags into `command:`.

For helpers that emit shell flags, use `contains` against `spec.template.spec.containers[0].command`.

- [ ] **Step 1: Write the suite**

Create `charts/arcadedb/tests/helpers_test.yaml`:

```yaml
suite: Template helpers (asserted via StatefulSet)
templates:
  - statefulset.yaml
release:
  name: test
  namespace: default
tests:
  - it: arcadedb.fullname produces release-name + chart-name when release name does not contain chart name
    asserts:
      - equal: { path: metadata.name, value: test-arcadedb }

  - it: arcadedb.fullname uses release name alone when it already contains chart name
    release:
      name: my-arcadedb
    asserts:
      - equal: { path: metadata.name, value: my-arcadedb }

  - it: fullnameOverride wins over auto-derived fullname
    set:
      fullnameOverride: custom-name
    asserts:
      - equal: { path: metadata.name, value: custom-name }

  - it: arcadedb.k8sSuffix appears in HA command flag
    set:
      replicaCount: 3
    asserts:
      - contains:
          path: spec.template.spec.containers[0].command
          content: "-Darcadedb.ha.k8sSuffix=.test-arcadedb.default.svc.cluster.local"

  - it: arcadedb.nodenames produces FQDN list sized to replicaCount when HPA disabled
    set:
      replicaCount: 3
    asserts:
      - contains:
          path: spec.template.spec.containers[0].command
          content: "-Darcadedb.ha.serverList=test-arcadedb-0.test-arcadedb.default.svc.cluster.local:2434,test-arcadedb-1.test-arcadedb.default.svc.cluster.local:2434,test-arcadedb-2.test-arcadedb.default.svc.cluster.local:2434"

  - it: arcadedb.nodenames sizes to autoscaling.maxReplicas when HPA enabled and larger than replicaCount
    set:
      replicaCount: 3
      autoscaling.enabled: true
      autoscaling.minReplicas: 3
      autoscaling.maxReplicas: 5
    asserts:
      - contains:
          path: spec.template.spec.containers[0].command
          content: "-Darcadedb.ha.serverList=test-arcadedb-0.test-arcadedb.default.svc.cluster.local:2434,test-arcadedb-1.test-arcadedb.default.svc.cluster.local:2434,test-arcadedb-2.test-arcadedb.default.svc.cluster.local:2434,test-arcadedb-3.test-arcadedb.default.svc.cluster.local:2434,test-arcadedb-4.test-arcadedb.default.svc.cluster.local:2434"

  - it: arcadedb.nodenames uses custom rpc port
    set:
      replicaCount: 2
      service.rpc.port: 5555
    asserts:
      - contains:
          path: spec.template.spec.containers[0].command
          content: "-Darcadedb.ha.serverList=test-arcadedb-0.test-arcadedb.default.svc.cluster.local:5555,test-arcadedb-1.test-arcadedb.default.svc.cluster.local:5555"

  - it: arcadedb.plugin.parameters emits gremlin plugin entry and port
    set:
      arcadedb.plugins.gremlin.enabled: true
      arcadedb.plugins.gremlin.port: 8182
    asserts:
      - contains:
          path: spec.template.spec.containers[0].command
          content: "-Darcadedb.server.plugins=GremlinServer:com.arcadedb.server.gremlin.GremlinServerPlugin"
      - contains:
          path: spec.template.spec.containers[0].command
          content: "-Darcadedb.gremlin.port=8182"

  - it: arcadedb.plugin.parameters emits postgres plugin entry and port
    set:
      arcadedb.plugins.postgres.enabled: true
      arcadedb.plugins.postgres.port: 5432
    asserts:
      - contains:
          path: spec.template.spec.containers[0].command
          content: "-Darcadedb.server.plugins=Postgres:com.arcadedb.postgres.PostgresProtocolPlugin"
      - contains:
          path: spec.template.spec.containers[0].command
          content: "-Darcadedb.postgres.port=5432"

  - it: arcadedb.plugin.parameters emits prometheus plugin without port flag
    set:
      arcadedb.plugins.prometheus.enabled: true
    asserts:
      - contains:
          path: spec.template.spec.containers[0].command
          content: "-Darcadedb.server.plugins=Prometheus:com.arcadedb.metrics.prometheus.PrometheusMetricsPlugin"
      - notContains:
          path: spec.template.spec.containers[0].command
          content: "-Darcadedb.prometheus.port=0"

  - it: arcadedb.plugin.parameters emits custom plugin entry with class
    set:
      arcadedb.plugins.myplugin.enabled: true
      arcadedb.plugins.myplugin.port: 1234
      arcadedb.plugins.myplugin.class: com.example.MyPlugin
    asserts:
      - contains:
          path: spec.template.spec.containers[0].command
          content: "-Darcadedb.server.plugins=myplugin:com.example.MyPlugin"
```

- [ ] **Step 2: Run the suite**

Run: `make test-unit`
Expected: all suites pass; Helpers suite reports 11 tests.

If the `arcadedb.nodenames` test fails on ordering, note that the helper iterates `until $replicas` which produces ordinal 0..N-1 in order — the expected string above is correct. If a plugin parameter test fails on substring matching, dump the rendered StatefulSet command list with `helm template charts/arcadedb --set arcadedb.plugins.gremlin.enabled=true | grep -A30 command:` to verify what's actually emitted.

- [ ] **Step 3: Commit**

```bash
git add charts/arcadedb/tests/helpers_test.yaml
git commit -m "test: add helm-unittest helpers suite via StatefulSet"
```

---

## Task 14: StatefulSet suite — part A (metadata, image, ports, probes, replicas, HA toggle)

**Files:**
- Create: `charts/arcadedb/tests/statefulset_test.yaml`

The StatefulSet suite is large enough to write in two passes for clarity. Part A covers the structural baseline. Part B (next task) covers the optional / pass-through fields and persistence/secret/security wiring.

- [ ] **Step 1: Write part A of the suite**

Create `charts/arcadedb/tests/statefulset_test.yaml`:

```yaml
suite: StatefulSet
templates:
  - statefulset.yaml
release:
  name: test
  namespace: default
tests:
  - it: renders one StatefulSet by default
    asserts:
      - hasDocuments: { count: 1 }
      - isKind: { of: StatefulSet }
      - equal: { path: metadata.name, value: test-arcadedb }
      - equal: { path: spec.serviceName, value: test-arcadedb }

  - it: default replicas is 1
    asserts:
      - equal: { path: spec.replicas, value: 1 }

  - it: replicas field is omitted when autoscaling is enabled
    set:
      autoscaling.enabled: true
      autoscaling.minReplicas: 3
      autoscaling.maxReplicas: 5
    asserts:
      - notExists: { path: spec.replicas }

  - it: respects custom replicaCount
    set:
      replicaCount: 3
    asserts:
      - equal: { path: spec.replicas, value: 3 }

  - it: selector matches expected app labels
    asserts:
      - equal:
          path: spec.selector.matchLabels["app.kubernetes.io/name"]
          value: arcadedb
      - equal:
          path: spec.selector.matchLabels["app.kubernetes.io/instance"]
          value: test

  - it: image string composes registry/repository:tag, defaulting tag to AppVersion
    asserts:
      - equal:
          path: spec.template.spec.containers[0].image
          value: arcadedata/arcadedb:26.4.2

  - it: image.tag override wins over AppVersion default
    set:
      image.tag: "27.0.0-rc1"
    asserts:
      - equal:
          path: spec.template.spec.containers[0].image
          value: arcadedata/arcadedb:27.0.0-rc1

  - it: image.registry and image.repository overrides flow through
    set:
      image.registry: my-registry.example.com
      image.repository: arcadedb-fork
    asserts:
      - equal:
          path: spec.template.spec.containers[0].image
          value: my-registry.example.com/arcadedb-fork:26.4.2

  - it: image.pullPolicy default is IfNotPresent and is overridable
    asserts:
      - equal: { path: spec.template.spec.containers[0].imagePullPolicy, value: IfNotPresent }

  - it: image.pullPolicy override flows through
    set:
      image.pullPolicy: Always
    asserts:
      - equal: { path: spec.template.spec.containers[0].imagePullPolicy, value: Always }

  - it: container exposes http port 2480 and rpc port 2434 by default
    asserts:
      - contains:
          path: spec.template.spec.containers[0].ports
          content: { name: http, containerPort: 2480, protocol: TCP }
      - contains:
          path: spec.template.spec.containers[0].ports
          content: { name: rpc, containerPort: 2434, protocol: TCP }

  - it: container ports reflect custom service.http.port and service.rpc.port
    set:
      service.http.port: 9090
      service.rpc.port: 5555
    asserts:
      - contains:
          path: spec.template.spec.containers[0].ports
          content: { name: http, containerPort: 9090, protocol: TCP }
      - contains:
          path: spec.template.spec.containers[0].ports
          content: { name: rpc, containerPort: 5555, protocol: TCP }

  - it: liveness and readiness probes default to /api/v1/ready on http port
    asserts:
      - equal:
          path: spec.template.spec.containers[0].livenessProbe.httpGet.path
          value: /api/v1/ready
      - equal:
          path: spec.template.spec.containers[0].livenessProbe.httpGet.port
          value: http
      - equal:
          path: spec.template.spec.containers[0].readinessProbe.httpGet.path
          value: /api/v1/ready
      - equal:
          path: spec.template.spec.containers[0].readinessProbe.httpGet.port
          value: http

  - it: HA flags are absent when replicaCount is 1 and autoscaling is disabled
    asserts:
      - notContains:
          path: spec.template.spec.containers[0].command
          content: "-Darcadedb.ha.enabled=true"
      - notContains:
          path: spec.template.spec.containers[0].command
          content: "-Darcadedb.ha.k8s=true"

  - it: HA flags render when replicaCount > 1
    set:
      replicaCount: 3
    asserts:
      - contains:
          path: spec.template.spec.containers[0].command
          content: "-Darcadedb.ha.enabled=true"
      - contains:
          path: spec.template.spec.containers[0].command
          content: "-Darcadedb.ha.k8s=true"
      - contains:
          path: spec.template.spec.containers[0].command
          content: "-Darcadedb.ha.raftPort=2434"

  - it: HA flags render when autoscaling is enabled even with replicaCount 1
    set:
      autoscaling.enabled: true
      autoscaling.minReplicas: 3
      autoscaling.maxReplicas: 5
    asserts:
      - contains:
          path: spec.template.spec.containers[0].command
          content: "-Darcadedb.ha.enabled=true"

  - it: serviceAccountName flows from arcadedb.serviceAccountName helper
    asserts:
      - equal: { path: spec.template.spec.serviceAccountName, value: test-arcadedb }

  - it: serviceAccountName falls back to "default" when create=false and no name
    set:
      serviceAccount.create: false
    asserts:
      - equal: { path: spec.template.spec.serviceAccountName, value: default }

  - it: serviceAccountName uses custom name when provided
    set:
      serviceAccount.name: my-sa
    asserts:
      - equal: { path: spec.template.spec.serviceAccountName, value: my-sa }

  - it: env contains HOSTNAME from metadata.name field reference
    asserts:
      - contains:
          path: spec.template.spec.containers[0].env
          content:
            name: HOSTNAME
            valueFrom:
              fieldRef:
                fieldPath: metadata.name

  - it: env contains POD_ID from status.podIP field reference
    asserts:
      - contains:
          path: spec.template.spec.containers[0].env
          content:
            name: POD_ID
            valueFrom:
              fieldRef:
                fieldPath: status.podIP
```

- [ ] **Step 2: Run the suite**

Run: `make test-unit`
Expected: all suites pass; StatefulSet suite reports 21 tests so far.

- [ ] **Step 3: Commit**

```bash
git add charts/arcadedb/tests/statefulset_test.yaml
git commit -m "test: add helm-unittest StatefulSet suite (structural baseline)"
```

---

## Task 15: StatefulSet suite — part B (security, persistence, secrets, optional fields)

**Files:**
- Modify: `charts/arcadedb/tests/statefulset_test.yaml` — append more `tests:` entries.

- [ ] **Step 1: Append the additional tests**

Append the following test blocks to the bottom of `charts/arcadedb/tests/statefulset_test.yaml`, under the existing `tests:` list. Maintain the same indentation as the existing tests.

```yaml
  - it: pod-level security context defaults render
    asserts:
      - equal: { path: spec.template.spec.securityContext.runAsNonRoot, value: true }
      - equal: { path: spec.template.spec.securityContext.fsGroup, value: 1000 }

  - it: container-level security context defaults render
    asserts:
      - equal:
          path: spec.template.spec.containers[0].securityContext.runAsUser
          value: 1000
      - equal:
          path: spec.template.spec.containers[0].securityContext.runAsGroup
          value: 1000
      - equal:
          path: spec.template.spec.containers[0].securityContext.allowPrivilegeEscalation
          value: false
      - equal:
          path: spec.template.spec.containers[0].securityContext.capabilities.drop[0]
          value: ALL

  - it: pod-level security context can be overridden
    set:
      podSecurityContext:
        runAsNonRoot: false
        fsGroup: 2000
    asserts:
      - equal: { path: spec.template.spec.securityContext.runAsNonRoot, value: false }
      - equal: { path: spec.template.spec.securityContext.fsGroup, value: 2000 }

  - it: persistence enabled by default renders volumeMount and volumeClaimTemplate
    asserts:
      - contains:
          path: spec.template.spec.containers[0].volumeMounts
          content:
            name: arcadedb-data
            mountPath: /home/arcadedb/databases
      - equal:
          path: spec.volumeClaimTemplates[0].metadata.name
          value: arcadedb-data
      - equal:
          path: spec.volumeClaimTemplates[0].spec.accessModes[0]
          value: ReadWriteOnce
      - equal:
          path: spec.volumeClaimTemplates[0].spec.resources.requests.storage
          value: 8Gi

  - it: persistence disabled removes volumeMount and volumeClaimTemplate
    set:
      persistence.enabled: false
    asserts:
      - notContains:
          path: spec.template.spec.containers[0].volumeMounts
          content: { name: arcadedb-data, mountPath: /home/arcadedb/databases }
      - lengthEqual: { path: spec.volumeClaimTemplates, count: 0 }

  - it: persistence size and storageClass overrides flow through
    set:
      persistence.size: 100Gi
      persistence.storageClass: fast-ssd
    asserts:
      - equal:
          path: spec.volumeClaimTemplates[0].spec.resources.requests.storage
          value: 100Gi
      - equal:
          path: spec.volumeClaimTemplates[0].spec.storageClassName
          value: fast-ssd

  - it: persistence accessMode override flows through
    set:
      persistence.accessMode: ReadWriteMany
    asserts:
      - equal:
          path: spec.volumeClaimTemplates[0].spec.accessModes[0]
          value: ReadWriteMany

  - it: rootPassword env defaults to auto-generated secret
    asserts:
      - contains:
          path: spec.template.spec.containers[0].env
          content:
            name: rootPassword
            valueFrom:
              secretKeyRef:
                name: arcadedb-credentials-secret
                key: rootPassword

  - it: rootPassword env points at user-supplied secret when configured
    set:
      arcadedb.credentials.rootPassword.secret.name: my-secret
      arcadedb.credentials.rootPassword.secret.key: my-key
    asserts:
      - contains:
          path: spec.template.spec.containers[0].env
          content:
            name: rootPassword
            valueFrom:
              secretKeyRef:
                name: my-secret
                key: my-key
                optional: false

  - it: imagePullSecrets flow through when set
    set:
      imagePullSecrets:
        - name: regcred
    asserts:
      - contains:
          path: spec.template.spec.imagePullSecrets
          content: { name: regcred }

  - it: imagePullSecrets are absent by default
    asserts:
      - notExists: { path: spec.template.spec.imagePullSecrets }

  - it: podAnnotations flow through
    set:
      podAnnotations:
        prometheus.io/scrape: "true"
    asserts:
      - equal:
          path: spec.template.metadata.annotations["prometheus.io/scrape"]
          value: "true"

  - it: podLabels flow through (merged with chart labels)
    set:
      podLabels:
        my-team: data
    asserts:
      - equal:
          path: spec.template.metadata.labels["my-team"]
          value: data
      - equal:
          path: spec.template.metadata.labels["app.kubernetes.io/name"]
          value: arcadedb

  - it: nodeSelector flows through
    set:
      nodeSelector:
        disktype: ssd
    asserts:
      - equal:
          path: spec.template.spec.nodeSelector.disktype
          value: ssd

  - it: tolerations flow through
    set:
      tolerations:
        - key: dedicated
          operator: Equal
          value: arcadedb
          effect: NoSchedule
    asserts:
      - contains:
          path: spec.template.spec.tolerations
          content: { key: dedicated, operator: Equal, value: arcadedb, effect: NoSchedule }

  - it: affinity defaults render podAntiAffinity
    asserts:
      - exists:
          path: spec.template.spec.affinity.podAntiAffinity.preferredDuringSchedulingIgnoredDuringExecution

  - it: affinity can be overridden
    set:
      affinity:
        nodeAffinity:
          requiredDuringSchedulingIgnoredDuringExecution:
            nodeSelectorTerms:
              - matchExpressions:
                  - key: kubernetes.io/os
                    operator: In
                    values: [linux]
    asserts:
      - exists:
          path: spec.template.spec.affinity.nodeAffinity
      - notExists:
          path: spec.template.spec.affinity.podAntiAffinity

  - it: resources flow through when set
    set:
      resources:
        requests: { cpu: 500m, memory: 2Gi }
        limits: { memory: 4Gi }
    asserts:
      - equal: { path: spec.template.spec.containers[0].resources.requests.cpu, value: 500m }
      - equal: { path: spec.template.spec.containers[0].resources.requests.memory, value: 2Gi }
      - equal: { path: spec.template.spec.containers[0].resources.limits.memory, value: 4Gi }

  - it: resources are empty by default
    asserts:
      - isEmpty: { path: spec.template.spec.containers[0].resources }

  - it: arcadedb.extraCommands appear in container command
    asserts:
      - contains:
          path: spec.template.spec.containers[0].command
          content: "-Darcadedb.server.mode=production"

  - it: arcadedb.extraEnvironment flows through to env
    set:
      arcadedb.extraEnvironment:
        - name: MY_VAR
          value: my-value
    asserts:
      - contains:
          path: spec.template.spec.containers[0].env
          content: { name: MY_VAR, value: my-value }

  - it: extra volumes flow through
    set:
      volumes:
        - name: config
          configMap:
            name: my-config
    asserts:
      - contains:
          path: spec.template.spec.volumes
          content:
            name: config
            configMap: { name: my-config }

  - it: extra volumeMounts flow through
    set:
      volumeMounts:
        - name: config
          mountPath: /etc/arcadedb
    asserts:
      - contains:
          path: spec.template.spec.containers[0].volumeMounts
          content: { name: config, mountPath: /etc/arcadedb }

  - it: extra volumeClaimTemplates flow through alongside the data PVC
    set:
      volumeClaimTemplates:
        - metadata: { name: arcadedb-config }
          spec:
            accessModes: [ReadWriteOnce]
            resources: { requests: { storage: 1Gi } }
    asserts:
      - lengthEqual: { path: spec.volumeClaimTemplates, count: 2 }
      - equal:
          path: spec.volumeClaimTemplates[1].metadata.name
          value: arcadedb-config

  - it: command includes default databaseDirectory and defaultDatabases flags
    asserts:
      - contains:
          path: spec.template.spec.containers[0].command
          content: "-Darcadedb.server.databaseDirectory=/home/arcadedb/databases"
      - contains:
          path: spec.template.spec.containers[0].command
          content: "-Darcadedb.server.defaultDatabases="

  - it: arcadedb.databaseDirectory and defaultDatabases flow through
    set:
      arcadedb.databaseDirectory: /custom/dir
      arcadedb.defaultDatabases: "Universe[admin:pwd]"
    asserts:
      - contains:
          path: spec.template.spec.containers[0].command
          content: "-Darcadedb.server.databaseDirectory=/custom/dir"
      - contains:
          path: spec.template.spec.containers[0].command
          content: "-Darcadedb.server.defaultDatabases=Universe[admin:pwd]"
```

- [ ] **Step 2: Run the suite**

Run: `make test-unit`
Expected: all suites pass; StatefulSet suite now reports ~46 tests (21 + 25). Total across all suites: ~80.

- [ ] **Step 3: Commit**

```bash
git add charts/arcadedb/tests/statefulset_test.yaml
git commit -m "test: extend StatefulSet suite with security, persistence, and pass-through field coverage"
```

---

## Task 16: Restructure CI workflow

**Files:**
- Modify: `.github/workflows/lint.yml`

Split the existing single `lint` job into three jobs: `lint`, `unittest`, `integration`. Preserve the action SHAs from the current file. Drop the six `helm template` steps and the bash quorum-guard incantation — they are now covered by the unittest suites.

- [ ] **Step 1: Read the current SHAs**

Run: `grep -n "uses:" .github/workflows/lint.yml`
Note the SHAs for `actions/checkout` and `azure/setup-helm`. The new file must reuse them.

- [ ] **Step 2: Replace the workflow**

Overwrite `.github/workflows/lint.yml` with this content, **using the SHAs you read in Step 1** (the values shown below match the current file at the time of writing — re-verify before committing):

```yaml
name: Lint

on:
  push:
    branches: [main]
  pull_request:
    branches: [main]

permissions:
  contents: read

jobs:
  lint:
    runs-on: ubuntu-24.04
    steps:
      - name: Checkout
        uses: actions/checkout@34e114876b0b11c390a56381ad16ebd13914f8d5 # v4.3.1

      - name: Set up Helm
        uses: azure/setup-helm@1a275c3b69536ee54be43f2070a358922e12c8d4 # v4.3.1
        with:
          version: v3.14.0

      - name: helm lint
        run: make lint

  unittest:
    runs-on: ubuntu-24.04
    steps:
      - name: Checkout
        uses: actions/checkout@34e114876b0b11c390a56381ad16ebd13914f8d5 # v4.3.1

      - name: Set up Helm
        uses: azure/setup-helm@1a275c3b69536ee54be43f2070a358922e12c8d4 # v4.3.1
        with:
          version: v3.14.0

      - name: helm unittest
        run: make test-unit

  integration:
    runs-on: ubuntu-24.04
    timeout-minutes: 20
    steps:
      - name: Checkout
        uses: actions/checkout@34e114876b0b11c390a56381ad16ebd13914f8d5 # v4.3.1

      - name: Install kind
        run: |
          curl -sLo /tmp/kind-linux-amd64 \
            https://kind.sigs.k8s.io/dl/v0.23.0/kind-linux-amd64
          curl -sLo /tmp/kind.sha256 \
            https://kind.sigs.k8s.io/dl/v0.23.0/kind-linux-amd64.sha256sum
          (cd /tmp && sha256sum -c kind.sha256)
          install -m 0755 /tmp/kind-linux-amd64 /usr/local/bin/kind

      - name: Install kubectl
        run: |
          curl -sLo /tmp/kubectl \
            "https://dl.k8s.io/release/v1.30.0/bin/linux/amd64/kubectl"
          curl -sLo /tmp/kubectl.sha256 \
            "https://dl.k8s.io/release/v1.30.0/bin/linux/amd64/kubectl.sha256"
          echo "$(cat /tmp/kubectl.sha256)  /tmp/kubectl" | sha256sum -c -
          install -m 0755 /tmp/kubectl /usr/local/bin/kubectl

      - name: Set up Helm
        uses: azure/setup-helm@1a275c3b69536ee54be43f2070a358922e12c8d4 # v4.3.1
        with:
          version: v3.14.0

      - name: Create kind cluster
        run: kind create cluster --wait 60s

      - name: Install chart
        run: |
          helm install test-arcadedb charts/arcadedb/ \
            --set replicaCount=3 \
            --set image.tag=latest \
            --set persistence.enabled=false \
            --set arcadedb.defaultDatabases="" \
            --timeout 5m \
            --wait

      - name: Run integration tests
        run: make test-integration

      - name: Delete kind cluster
        if: always()
        run: kind delete cluster
```

- [ ] **Step 3: Validate workflow syntax locally**

If you have `actionlint` available:
```bash
actionlint .github/workflows/lint.yml
```
Expected: no errors.

If `actionlint` isn't installed, skip this step — the next step will catch syntax issues in CI.

- [ ] **Step 4: Verify each Make target works locally**

```bash
make lint
make test-unit
```
Both expected: exit 0. (Skip `make test-integration` locally unless you have a kind cluster ready — CI exercises it.)

- [ ] **Step 5: Commit**

```bash
git add .github/workflows/lint.yml
git commit -m "ci: split lint workflow into lint/unittest/integration jobs"
```

---

## Task 17: Add a "Development" section to the README

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Read the current README**

Read `README.md` to find a good insertion point — between "Configuration" and "Release" sections.

- [ ] **Step 2: Insert the Development section**

Use the Edit tool to insert this section after the `## Configuration` block and before `## Release`:

```markdown
## Development

Run checks locally:

```
make help              # list available targets
make lint              # helm lint
make test-unit         # helm-unittest suites (auto-installs the plugin)
make test-integration  # kind-based end-to-end tests (requires Docker)
make test              # run all of the above
```

The unit-test suites live in `charts/arcadedb/tests/` and use [helm-unittest](https://github.com/helm-unittest/helm-unittest). The plugin version is pinned in the `Makefile`.
```

(Wrap the inner triple-backtick block as a fenced code block at depth 4 backticks if your renderer requires it. The standard 3-backtick form works in GitHub-flavored Markdown.)

- [ ] **Step 3: Verify the README renders**

Run: `git diff README.md`
Visually check the diff for correct insertion.

- [ ] **Step 4: Commit**

```bash
git add README.md
git commit -m "docs: add Development section with make targets"
```

---

## Task 18: Final end-to-end verification

- [ ] **Step 1: Run the full test target**

Run: `make lint test-unit`
Expected: both pass with exit 0. `make test-unit` reports approximately:
```
Charts:      1 passed, 1 total
Test Suites: 11 passed, 11 total
Tests:       ~80 passed, 0 failed
```

(`test-integration` requires Docker + kind locally — CI handles it.)

- [ ] **Step 2: Verify packaged chart excludes tests/**

Run:
```bash
helm package charts/arcadedb -d /tmp/
tar tzf /tmp/arcadedb-26.4.2.tgz | grep -c tests/ || echo "OK: tests/ excluded"
rm /tmp/arcadedb-26.4.2.tgz
```
Expected: `OK: tests/ excluded`.

- [ ] **Step 3: Push branch and open PR**

```bash
git push -u origin feat/migrate-to-heml-unittest
gh pr create --title "Migrate template assertions to helm-unittest" --body "$(cat <<'EOF'
## Summary
- Replaces ad-hoc `helm template … | grep` checks with full-coverage helm-unittest suites under `charts/arcadedb/tests/`
- Restructures `lint.yml` into three parallel jobs: `lint`, `unittest`, `integration`
- Adds a top-level `Makefile` as the single entry point for `lint`, `test-unit`, `test-integration`
- Adds `.helmignore` so test files are excluded from the packaged chart
- Documents local workflow in the README

Design: `docs/superpowers/specs/2026-05-04-helm-unittest-migration-design.md`
Plan:   `docs/superpowers/plans/2026-05-04-helm-unittest-migration.md`

## Test plan
- [ ] CI `lint` job green
- [ ] CI `unittest` job green (~80 tests across 11 suites)
- [ ] CI `integration` job green (kind cluster, unchanged behavior)
- [ ] Confirm branch protection still gates on the right job names (may need an admin update if previously gated on the single `lint` job)

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

Expected: PR URL printed.

---

## Self-Review Notes

**Spec coverage check:** All eleven suites from the design are present (Tasks 4–15). Makefile (Task 1), `.helmignore` (Task 2), CI restructure (Task 16), README (Task 17) all covered.

**Type/name consistency check:** Release name is `test` everywhere; chart name is `arcadedb`; fullname is `test-arcadedb`. Plugin parameter strings (`-Darcadedb.server.plugins=…`, `-Darcadedb.gremlin.port=…`) match the actual emit in `_helpers.tpl`. `arcadedb.k8sSuffix` value `.test-arcadedb.default.svc.cluster.local` derives from `printf ".%s.%s.svc.cluster.local" $fullname .Release.Namespace` — verified.

**Areas of moderate risk during execution:**

1. helm-unittest path syntax for map keys with dots: tests use `metadata.annotations["prometheus.io/scrape"]` — this is the documented v0.5.x syntax. If a path assertion fails on something that "should" work, double-check the path expression by running `helm unittest -v <suite>` for verbose output.
2. NOTES.txt assertions use `path: ""` to match the whole rendered text; if your local plugin version differs, switch to `path: "$"`.
3. The `arcadedb.nodenames` helper builds the FQDN list deterministically by ordinal — assertion strings in Task 13 are pre-computed; verify against actual output if a test fails.
4. The chart auto-generates the credentials secret with a 32-char random base64 password; the regex `^[A-Za-z0-9+/]{43}=$` covers the standard base64 encoding of 32 random bytes (32 × 4 / 3 = 42.67 → 43 chars + 1 padding). If the chart ever switches to `randAlphaNum 32 | b64enc`, this still holds because alphanumerics encode the same way through `b64enc`.
