# ArcadeDB Helm Chart

[![Artifact Hub](https://img.shields.io/endpoint?url=https://artifacthub.io/badge/repository/arcadedb)](https://artifacthub.io/packages/helm/arcadedb/arcadedb) [![CI](https://github.com/ArcadeData/arcadedb-helm/actions/workflows/lint.yml/badge.svg)](https://github.com/ArcadeData/arcadedb-helm/actions/workflows/lint.yml)

The official Helm chart for [ArcadeDB](https://arcadedb.com/), a multi-model database supporting SQL, Cypher, Gremlin, MongoDB, and Redis protocols.

## Install

```bash
helm repo add arcadedb https://helm.arcadedb.com/
helm repo update
helm install my-arcadedb arcadedb/arcadedb
```

## Configuration

See [charts/arcadedb/README.md](charts/arcadedb/README.md) and [charts/arcadedb/values.yaml](charts/arcadedb/values.yaml) for all available options.

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

**OTLP metrics export** (alongside /prometheus) — append to the install/upgrade command:

```bash
--set observability.metrics.otlp.enabled=true \
--set observability.metrics.otlp.endpoint=http://otel-collector:4317
```

**Distributed tracing** — append to the install/upgrade command:

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

## Development

Run checks locally:

```bash
make help              # list available targets
make lint              # helm lint
make test-unit         # helm-unittest suites (auto-installs the plugin)
make test-integration  # kind-based end-to-end tests (requires Docker)
make test              # run all of the above
```

Unit-test suites live in `charts/arcadedb/tests/` and use [helm-unittest](https://github.com/helm-unittest/helm-unittest). The plugin version is pinned in the `Makefile`.

### Latest-image guard

`.github/workflows/latest-image.yml` runs the full kind HA integration suite
against the rolling `arcadedata/arcadedb:latest` image every Monday (and on
manual `workflow_dispatch`). It is a **blocking** pre-release guard: a red run
means the upcoming ArcadeDB release breaks the chart. It shares its steps with
the PR integration job via `.github/workflows/integration-reusable.yml`, so both
exercise an identical suite differing only by image tag.

### Release-bump checklist

When a new ArcadeDB version is released:

1. Bump `version` and `appVersion` in `charts/arcadedb/Chart.yaml`.
2. Update the pinned image literal in `charts/arcadedb/tests/statefulset_test.yaml`
   to the new version, or `helm-unittest` will fail (it cannot reference
   `Chart.AppVersion` in an assertion).
3. If `appVersion` was bumped **ahead of** the matching image being published
   (so a feature can ship as soon as the image lands), the PR integration job —
   which installs with `image.tag=appVersion` — cannot pull the image and will
   time out. As a stopgap, the integration job in `.github/workflows/lint.yml`
   carries a temporary `with: { imageTag: latest, pullPolicy: Always }` override
   (`latest` tracks the upcoming release). Once the pinned image is published,
   **remove that override** so the PR job tests the pinned `appVersion` again.
4. The latest-image guard needs no change — it keeps watching the next cycle's
   rolling image.

> **Pending — 26.7.1:** the chart is already at `appVersion: 26.7.1` (the
> observability feature shipped ahead of the image), and the integration job is
> temporarily pinned to `latest` per step 3. When `arcadedata/arcadedb:26.7.1`
> is published, remove the `with:` override in `.github/workflows/lint.yml`,
> re-run CI, and delete this note. Steps 1–2 are already done for this release.

## Release

New chart versions are published via the GitHub Actions Release workflow:

```
GitHub → Actions → Release → Run workflow → enter version → Run
```

## Contributing

PRs welcome. The lint workflow runs on all pull requests.
