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

## Release

New chart versions are published via the GitHub Actions Release workflow:

```
GitHub → Actions → Release → Run workflow → enter version → Run
```

## Contributing

PRs welcome. The lint workflow runs on all pull requests.
