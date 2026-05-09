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

pf_wait() {   # pf_wait <local-port> [max-attempts]
  local port=$1 attempts=${2:-10} i
  for (( i=0; i<attempts; i++ )); do
    curl -sf --max-time 1 "http://localhost:${port}/api/v1/ready" \
      --user "root:${PASSWORD}" >/dev/null 2>&1 && return 0
    sleep 0.5
  done
  return 1
}

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

cleanup() {
  [[ -n "${PF_PID:-}" ]] && { kill "$PF_PID" 2>/dev/null || true; }
}
trap cleanup EXIT

# assert_quorum_n <expected-pod-count> [timeout-seconds]
# Polls all pods 0..N-1 until they all report the same non-empty leaderId.
# On success: exports LEADERS[] (array of leaderIds, one per pod) and
# LEADER_ORDINAL (the pod ordinal of the leader).
assert_quorum_n() {
  local n=$1 timeout=${2:-$RAFT_TIMEOUT}
  local deadline=$(( SECONDS + timeout ))
  local i pid local_port l
  while true; do
    LEADERS=()
    for (( i=0; i<n; i++ )); do
      local_port=$(( HTTP_PORT + 10 + i ))
      pid=$(pf_start "$i" "$local_port")
      if pf_wait "$local_port"; then
        l=$(api "$local_port" GET /api/v1/cluster \
          | jq -r '.leaderId // empty' 2>/dev/null || echo "")
        LEADERS+=("$l")
      fi
      pf_stop "$pid"
    done

    if (( ${#LEADERS[@]} == n )) && [[ -n "${LEADERS[0]}" ]]; then
      local all_agree=1
      for l in "${LEADERS[@]:1}"; do
        [[ "$l" == "${LEADERS[0]}" ]] || { all_agree=0; break; }
      done
      if (( all_agree )); then
        LEADER_ORDINAL=$(echo "${LEADERS[0]}" \
          | sed -nE "s/^${RELEASE}-([0-9]+)\..*$/\1/p")
        [[ -n "$LEADER_ORDINAL" ]] || {
          echo "ERROR: could not parse ordinal from leader '${LEADERS[0]}'"
          return 1
        }
        echo "    Raft leader: ${LEADERS[0]} (pod-${LEADER_ORDINAL})"
        return 0
      fi
    fi

    if (( SECONDS >= deadline )); then
      echo "ERROR: Raft formation on ${n} pods timed out after ${timeout}s."
      echo "       Leaders seen: ${LEADERS[*]:-<none>}"
      return 1
    fi
    echo "    Not converged yet (${LEADERS[*]:-<none>}), retrying in 5s..."
    sleep 5
  done
}

# ── retrieve password ─────────────────────────────────────────────────────────

PASSWORD=$(kubectl get secret arcadedb-credentials-secret \
  -n "$NAMESPACE" \
  -o jsonpath='{.data.rootPassword}' | base64 -d)

[[ -n "$PASSWORD" ]] || { echo "ERROR: rootPassword secret is empty or missing"; exit 1; }

# ── phase 1: pod readiness ────────────────────────────────────────────────────

echo "==> [1/8] Waiting for StatefulSet rollout (timeout ${ROLLOUT_TIMEOUT}s)..."
kubectl rollout status statefulset/"$RELEASE" \
  -n "$NAMESPACE" --timeout="${ROLLOUT_TIMEOUT}s"
echo "    All 3 pods Ready."

# ── phase 2: raft formation ───────────────────────────────────────────────────

echo "==> [2/8] Checking Raft leader consensus (timeout ${RAFT_TIMEOUT}s)..."
assert_quorum_n 3 || exit 1

# ── phase 3: write ────────────────────────────────────────────────────────────

# LEADER_ORDINAL is set by assert_quorum_n above.

echo "==> [3/8] Writing test data via leader pod-${LEADER_ORDINAL}..."
PF_PID=$(pf_start "$LEADER_ORDINAL" "$HTTP_PORT")
pf_wait "$HTTP_PORT" || { echo "ERROR: port-forward to leader pod-${LEADER_ORDINAL} failed"; exit 1; }

api "$HTTP_PORT" POST /api/v1/server \
  '{"command":"create database integration-test"}' \
  >/dev/null

api "$HTTP_PORT" POST /api/v1/command/integration-test \
  '{"language":"sql","command":"CREATE document TYPE TestDoc IF NOT EXISTS"}' \
  >/dev/null

api "$HTTP_PORT" POST /api/v1/command/integration-test \
  '{"language":"sql","command":"INSERT INTO TestDoc SET name = '\''hello-kind'\''"}' \
  >/dev/null

echo "    Write complete."

# ── phase 4: read and assert ──────────────────────────────────────────────────

echo "==> [4/8] Reading back test data..."
RESULT=$(api "$HTTP_PORT" POST /api/v1/query/integration-test \
  '{"language":"sql","command":"SELECT name FROM TestDoc WHERE name = '\''hello-kind'\''"}' \
  | jq -r '.result[0].name // empty') || {
  echo "ERROR: read query failed"
  exit 1
}

pf_stop "$PF_PID"

if [[ "$RESULT" != "hello-kind" ]]; then
  echo "ERROR: Expected 'hello-kind', got '${RESULT:-<empty>}'"
  exit 1
fi

echo "    Got: '${RESULT}'"
echo "==> All checks passed."
