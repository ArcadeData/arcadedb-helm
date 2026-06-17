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
3. The latest-image guard needs no change — it keeps watching the next cycle's
   rolling image.

## Release

New chart versions are published via the GitHub Actions Release workflow:

```
GitHub → Actions → Release → Run workflow → enter version → Run
```

## Contributing

PRs welcome. The lint workflow runs on all pull requests.
