# Kind Integration Test Workflow Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a real-cluster integration test job to `lint.yml` that deploys a 3-pod ArcadeDB HA cluster on kind, checks Raft leader election, and asserts a write/read round trip via the HTTP API.

**Architecture:** A new `integration` job (parallel to `lint`) spins up a single-node kind cluster, installs the chart with `replicaCount=3` and `persistence.enabled=false`, then delegates all test logic to `ci/integration-test.sh`. The script runs four phases: wait for pod readiness, verify Raft leader consensus across all 3 pods, write a document, read it back and assert. Cleanup always runs via `if: always()`.

**Tech Stack:** GitHub Actions, kind v0.23.0, kubectl v1.30.0, helm v3.14.0, bash, curl, jq

---

### Task 1: Create `ci/integration-test.sh`

**Files:**
- Create: `ci/integration-test.sh`

- [ ] **Step 1: Create the script file**

```bash
#!/usr/bin/env bash
set -euo pipefail

RELEASE=test-arcadedb
NAMESPACE=default
HTTP_PORT=2480
RAFT_TIMEOUT=60
ROLLOUT_TIMEOUT=120

# ── helpers ──────────────────────────────────────────────────────────────────

pf_start() {          # pf_start <pod-ordinal> <local-port>
  kubectl port-forward -n "$NAMESPACE" \
    "pod/${RELEASE}-${1}" "${2}:${HTTP_PORT}" \
    >/dev/null 2>&1 &
  echo $!
}

pf_stop() { kill "$1" 2>/dev/null || true; }

api() {               # api <local-port> <method> <path> [body]
  local port=$1 method=$2 path=$3 body=${4:-}
  if [[ -n "$body" ]]; then
    curl -sf --user "root:${PASSWORD}" \
      -X "$method" "http://localhost:${port}${path}" \
      -H "Content-Type: application/json" \
      -d "$body"
  else
    curl -sf --user "root:${PASSWORD}" \
      -X "$method" "http://localhost:${port}${path}"
  fi
}

# ── retrieve password ─────────────────────────────────────────────────────────

PASSWORD=$(kubectl get secret arcadedb-credentials-secret \
  -n "$NAMESPACE" \
  -o jsonpath='{.data.rootPassword}' | base64 -d)

# ── phase 1: pod readiness ────────────────────────────────────────────────────

echo "==> [1/4] Waiting for StatefulSet rollout (timeout ${ROLLOUT_TIMEOUT}s)..."
kubectl rollout status statefulset/"$RELEASE" \
  -n "$NAMESPACE" --timeout="${ROLLOUT_TIMEOUT}s"
echo "    All 3 pods Ready."

# ── phase 2: raft formation ───────────────────────────────────────────────────

echo "==> [2/4] Checking Raft leader consensus (timeout ${RAFT_TIMEOUT}s)..."
DEADLINE=$(( SECONDS + RAFT_TIMEOUT ))

while true; do
  LEADERS=()
  for i in 0 1 2; do
    LOCAL=$(( HTTP_PORT + 10 + i ))   # 2490, 2491, 2492
    PID=$(pf_start "$i" "$LOCAL")
    sleep 1
    LEADER=$(api "$LOCAL" GET /api/v1/server \
      | jq -r '.ha.leader // empty' 2>/dev/null || echo "")
    pf_stop "$PID"
    LEADERS+=("$LEADER")
  done

  if [[ -n "${LEADERS[0]}" \
     && "${LEADERS[0]}" == "${LEADERS[1]}" \
     && "${LEADERS[0]}" == "${LEADERS[2]}" ]]; then
    echo "    Raft leader: ${LEADERS[0]}"
    break
  fi

  if (( SECONDS >= DEADLINE )); then
    echo "ERROR: Raft formation timed out after ${RAFT_TIMEOUT}s."
    echo "       Leaders seen: ${LEADERS[*]:-<none>}"
    exit 1
  fi

  echo "    Not converged yet (${LEADERS[*]:-<none>}), retrying in 5s..."
  sleep 5
done

# ── phase 3: write ────────────────────────────────────────────────────────────

echo "==> [3/4] Writing test data via pod-0..."
PF_PID=$(pf_start 0 "$HTTP_PORT")
sleep 1

api "$HTTP_PORT" POST /api/v1/create/integration-test >/dev/null

api "$HTTP_PORT" POST /api/v1/command/integration-test \
  '{"language":"sql","command":"CREATE document TYPE TestDoc IF NOT EXISTS"}' \
  >/dev/null

api "$HTTP_PORT" POST /api/v1/command/integration-test \
  '{"language":"sql","command":"INSERT INTO TestDoc SET name = '\''hello-kind'\''"}' \
  >/dev/null

echo "    Write complete."

# ── phase 4: read and assert ──────────────────────────────────────────────────

echo "==> [4/4] Reading back test data..."
RESULT=$(api "$HTTP_PORT" POST /api/v1/query/integration-test \
  '{"language":"sql","command":"SELECT name FROM TestDoc WHERE name = '\''hello-kind'\''"}' \
  | jq -r '.result[0].name // empty')

pf_stop "$PF_PID"

if [[ "$RESULT" != "hello-kind" ]]; then
  echo "ERROR: Expected 'hello-kind', got '${RESULT:-<empty>}'"
  exit 1
fi

echo "    Got: '${RESULT}'"
echo "==> All checks passed."
```

Save this content to `ci/integration-test.sh`.

- [ ] **Step 2: Make the script executable**

```bash
chmod +x ci/integration-test.sh
```

- [ ] **Step 3: Verify the script is syntactically valid**

```bash
bash -n ci/integration-test.sh
```

Expected: no output, exit 0.

- [ ] **Step 4: Commit**

```bash
git add ci/integration-test.sh
git commit -m "feat(ci): add kind integration test script"
```

---

### Task 2: Add `integration` job to `.github/workflows/lint.yml`

**Files:**
- Modify: `.github/workflows/lint.yml`

- [ ] **Step 1: Read the current end of `lint.yml` to find the insertion point**

Open `.github/workflows/lint.yml` and note the last line of the `lint` job. The new `integration` job will be appended at the same indentation level.

- [ ] **Step 2: Append the `integration` job**

Add the following block at the end of `.github/workflows/lint.yml`, as a sibling to the `lint` job:

```yaml

  integration:
    runs-on: ubuntu-24.04
    steps:
      - name: Checkout
        uses: actions/checkout@34e114876b0b11c390a56381ad16ebd13914f8d5 # v4.3.1

      - name: Install kind
        run: |
          curl -sLo /usr/local/bin/kind \
            https://kind.sigs.k8s.io/dl/v0.23.0/kind-linux-amd64
          chmod +x /usr/local/bin/kind

      - name: Install kubectl
        run: |
          curl -sLo /usr/local/bin/kubectl \
            "https://dl.k8s.io/release/v1.30.0/bin/linux/amd64/kubectl"
          chmod +x /usr/local/bin/kubectl

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
        run: bash ci/integration-test.sh

      - name: Delete kind cluster
        if: always()
        run: kind delete cluster
```

- [ ] **Step 3: Verify the workflow YAML is valid**

```bash
python3 -c "import yaml, sys; yaml.safe_load(open('.github/workflows/lint.yml'))" \
  && echo "YAML valid"
```

Expected: `YAML valid`

- [ ] **Step 4: Commit**

```bash
git add .github/workflows/lint.yml
git commit -m "feat(ci): add kind integration test job to lint workflow"
```

---

## Notes for the implementer

**`/api/v1/server` leader field:** The script uses `.ha.leader` from the server response to check Raft consensus. Verify this field name by running `curl -s --user root:<pass> http://localhost:2480/api/v1/server | jq .` against a running HA cluster. If the field name differs (e.g. `.ha.leaderAddress`), update line 52 of `ci/integration-test.sh`.

**`persistence.enabled=false`:** kind's default StorageClass (`standard`) uses `hostPath` and works, but StatefulSet pod scheduling with multiple replicas on a single node can cause issues when all 3 PVCs compete for the same host path. Disabling persistence avoids this entirely — data lives only in the container's writable layer, which is fine for a test.

**Port offsets:** Phase 2 uses local ports 2490/2491/2492 to avoid conflicting with Phase 3's port-forward on 2480.
