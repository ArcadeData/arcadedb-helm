# Kind Integration Test Workflow

**Date:** 2026-04-30
**Status:** Approved

## Goal

Add a real cluster integration test to CI that deploys the ArcadeDB Helm chart onto a kind cluster, verifies Raft HA formation across 3 pods, and asserts write/read correctness via the HTTP API.

## Scope

- New `integration` job inside `.github/workflows/lint.yml`
- New script `ci/integration-test.sh` containing all test logic
- No changes to the chart itself

## Workflow Structure

### Job: `integration`

- Runner: `ubuntu-24.04`
- Triggers: same as `lint` job (push to `main`, PRs targeting `main`)
- Runs in parallel with `lint` (no `needs:` dependency)

Steps:
1. Checkout (`actions/checkout`)
2. Install `kind`, `kubectl`, `helm` (pinned versions)
3. Create a single-node kind cluster (`kind create cluster`)
4. `helm install test-arcadedb charts/arcadedb/` with overrides (see below)
5. Run `ci/integration-test.sh`
6. `kind delete cluster` (always runs via `if: always()`)

### Helm Install Overrides

```
replicaCount=3
image.tag=latest
persistence.enabled=false
arcadedb.defaultDatabases=""
```

`persistence.enabled=false` avoids needing a StorageClass in kind. The script creates the test database itself.

## Test Script: `ci/integration-test.sh`

### Phase 1 — Wait for pods

```bash
kubectl rollout status statefulset/test-arcadedb --timeout=120s
```

### Phase 2 — Raft formation check

Retrieve the auto-generated root password from the secret:

```bash
PASSWORD=$(kubectl get secret arcadedb-credentials-secret \
  -o jsonpath='{.data.rootPassword}' | base64 -d)
```

Open a temporary `kubectl port-forward` to each pod in turn and hit `/api/v1/server` with `curl`. Poll until all 3 report the same non-empty leader. Retry every 5s, timeout 60s. Fail loudly if quorum is not reached. (The ArcadeDB container is JRE-based and does not include `curl`, so all HTTP calls go through `port-forward` from the runner.)

### Phase 3 — Write

Open a `kubectl port-forward` to pod-0 on port 2480. Create a test database and insert one document via `POST /api/v1/command/{db}` with `--user root:$PASSWORD`.

### Phase 4 — Read and assert

Query the document back. Use `jq` to extract the value and assert it matches the expected value. Exit 1 with a clear message on mismatch.

### Dependencies

Uses only `kubectl`, `curl`, `jq` — all present on the `ubuntu-24.04` GHA runner. Takes no arguments; hardcodes the release name `test-arcadedb` to match what the workflow installs.

## Success Criteria

- All 3 ArcadeDB pods reach `Ready`
- All 3 pods agree on the same Raft leader
- A document written to pod-0 is readable back with correct content
- Cluster teardown always runs (no dangling kind clusters on failure)
