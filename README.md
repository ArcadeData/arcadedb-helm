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

## Storage

The database directory, the config directory (users, groups, API tokens) and,
when HA is active, the Raft log are each persisted on a per-replica PVC by
default (`persistence.enabled`, `persistence.config.enabled`,
`persistence.raft.enabled`). Logs and `/tmp` stay on `emptyDir`. Backups go to
`arcadedb.backupDirectory`, on the `/tmp` `emptyDir` unless
`persistence.backups.enabled` gives them a PVC. Disabling a
`persistence.*` flag backs that directory with an `emptyDir` and the install
notes warn that it is ephemeral. Extra claims go under `volumeClaimTemplates`.

**Upgrading from 26.10.2 or earlier:** those charts kept everything on
`emptyDir`, and moving to PVCs changes the StatefulSet's immutable
`volumeClaimTemplates`. Back up your databases, delete the StatefulSet, then
upgrade. See [Persistence](charts/arcadedb/README.md#persistence-1) for details.

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
readiness stays on `/api/v1/ready`. In HA clusters readiness is gated on Raft
membership and catch-up by default (`observability.health.readinessRequiresHA`
follows HA unless set explicitly), so a rolling restart never drops the write
quorum.

## Development

Run checks locally:

```bash
make help              # list available targets
make lint              # helm lint
make test-unit         # helm-unittest suites (auto-installs the plugin)
make test-config-keys  # rendered -Darcadedb.* keys exist in the server image (requires Docker)
make test-integration  # kind-based end-to-end tests (requires Docker)
make test              # run all of the above
```

Unit-test suites live in `charts/arcadedb/tests/` and use [helm-unittest](https://github.com/helm-unittest/helm-unittest). The plugin version is pinned in the `Makefile`.

`failedTemplate` assertions must use an exact `errorMessage`. The pinned plugin drops any other key, `errorPattern`
included, and a `failedTemplate` without `errorMessage` passes on any render failure. `make test-unit` therefore runs
`ci/check-failed-template.sh`, which rejects such assertions and runs the suite in `charts/arcadedb/tests/negative-control/`:
every assertion there must fail, which proves the plugin still compares `errorMessage` with the render error.

`make test-config-keys` renders the chart with representative values and checks that every `-Darcadedb.*` setting it
passes still exists in the server's `GlobalConfiguration` (the appVersion image by default, `IMAGE_TAG=...` to pick
another). The server ignores an unknown `-D` property silently, so a renamed setting would otherwise go unnoticed.
Known exceptions live in `ci/config-keys-allowlist.txt`, each with its tracking issue.

### Latest-image guard

`.github/workflows/latest-image.yml` runs the full kind HA integration suite
against the rolling `arcadedata/arcadedb:latest` image every Monday (and on
manual `workflow_dispatch`). It is a **blocking** pre-release guard: a red run
means the upcoming ArcadeDB release breaks the chart. It shares its steps with
the PR integration job via `.github/workflows/integration-reusable.yml`, so both
exercise an identical suite differing only by image tag.

The PR jobs in `.github/workflows/lint.yml` boot one cluster per route the chart
can take to hand the root password and the HA cluster token to the server:

| Job | Install | Route |
|---|---|---|
| `integration`, `integration-native` | HA, generated `arcadedb-credentials-secret` | password and token files |
| `integration-cluster-token` | HA, user root password Secret + user cluster token Secret | password and token files, from two Secrets |
| `integration-root-password-env` | HA, user root password Secret, no token, image 26.10.2 | `arcadedb.server.rootPassword` env var |
| `integration-single-node` | `replicaCount=1` | password file only |

The HA route with a user root password Secret, no token, and an image >= 26.11.1
(password file only, token derived from it) runs in the latest-image guard as
`integration-root-password-file-snapshot` until 26.11.1 is published.

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
   rolling image. The one exception is `integration-root-password-file-snapshot`
   in `.github/workflows/latest-image.yml`, which names the `26.11.1-SNAPSHOT`
   tag: once 26.11.1 is published, move it to `.github/workflows/lint.yml` with
   `imageTag: "26.11.1"` and drop `pullPolicy: Always`.
5. Leave the `integration-root-password-env` job in `.github/workflows/lint.yml`
   on its pinned pre-26.11.1 tag: it exists to boot the HA root-password
   env-var fallback, which the chart only takes on images older than 26.11.1.

## Release

New chart versions are published via the GitHub Actions Release workflow:

```
GitHub → Actions → Release → Run workflow → enter version → Run
```

## Contributing

PRs welcome. The lint workflow runs on all pull requests.
