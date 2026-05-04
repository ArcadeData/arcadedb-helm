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

# ── retrieve password ─────────────────────────────────────────────────────────

PASSWORD=$(kubectl get secret arcadedb-credentials-secret \
  -n "$NAMESPACE" \
  -o jsonpath='{.data.rootPassword}' | base64 -d)

[[ -n "$PASSWORD" ]] || { echo "ERROR: rootPassword secret is empty or missing"; exit 1; }

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
    pf_wait "$LOCAL" || { pf_stop "$PID"; continue; }
    LEADER=$(api "$LOCAL" GET /api/v1/cluster \
      | jq -r '.leaderId // empty' 2>/dev/null || echo "")
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

# Writes (including database creation) must go through the Raft leader. Parse the
# pod ordinal out of leaderId, e.g. "test-arcadedb-1.test-arcadedb.default..._2434" -> 1.
LEADER_ORDINAL=$(echo "${LEADERS[0]}" | sed -nE "s/^${RELEASE}-([0-9]+)\..*$/\1/p")
[[ -n "$LEADER_ORDINAL" ]] || { echo "ERROR: could not parse ordinal from leader '${LEADERS[0]}'"; exit 1; }

echo "==> [3/4] Writing test data via leader pod-${LEADER_ORDINAL}..."
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

echo "==> [4/4] Reading back test data..."
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
