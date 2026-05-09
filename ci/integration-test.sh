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

# cluster_status_assert_healthy <local-port>
# Asserts no peer is STALLED or FALLING_BEHIND. Gracefully skips if the
# `peers[].status` field is absent (image predates commit 203acdaac).
cluster_status_assert_healthy() {
  local port=$1
  local status_json has_status stalled peer_count
  status_json=$(api "$port" GET /api/v1/cluster) || {
    echo "ERROR: cluster status API call failed"; return 1
  }
  has_status=$(echo "$status_json" | jq -r '.peers[0].status // empty')
  if [[ -z "$has_status" ]]; then
    echo "    WARNING: peers[].status field absent on this image; skipping STATUS assertion."
    return 0
  fi
  stalled=$(echo "$status_json" \
    | jq -r '.peers[] | select(.status=="STALLED" or .status=="FALLING_BEHIND") | .id' \
    | head -n1)
  if [[ -n "$stalled" ]]; then
    echo "ERROR: peer $stalled has status STALLED/FALLING_BEHIND"
    echo "$status_json" | jq '.peers'
    return 1
  fi
  peer_count=$(echo "$status_json" | jq '.peers | length')
  echo "    All ${peer_count} peers HEALTHY/CATCHING_UP."
  return 0
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

# ── phase 5: STATUS column ────────────────────────────────────────────────────

echo "==> [5/8] Asserting STATUS=HEALTHY for all peers..."
PF_PID=$(pf_start "$LEADER_ORDINAL" "$HTTP_PORT")
pf_wait "$HTTP_PORT" || { echo "ERROR: port-forward to leader failed"; exit 1; }

cluster_status_assert_healthy "$HTTP_PORT" || exit 1

pf_stop "$PF_PID"

# ── phase 6: leadership transfer ──────────────────────────────────────────────

echo "==> [6/8] Transferring Raft leadership..."
PF_PID=$(pf_start "$LEADER_ORDINAL" "$HTTP_PORT")
pf_wait "$HTTP_PORT" || { echo "ERROR: port-forward to leader failed"; exit 1; }

CURRENT_LEADER=${LEADERS[0]}
TARGET_PEER=$(api "$HTTP_PORT" GET /api/v1/cluster \
  | jq -r --arg leader "$CURRENT_LEADER" \
    '.peers[] | select(.id != $leader) | .id' | head -n1)
[[ -n "$TARGET_PEER" ]] || { echo "ERROR: no non-leader peer found"; exit 1; }
echo "    Current leader: $CURRENT_LEADER"
echo "    Transfer target: $TARGET_PEER"

api "$HTTP_PORT" POST /api/v1/cluster/leader \
  "{\"peerId\":\"$TARGET_PEER\"}" >/dev/null
pf_stop "$PF_PID"

# Wait up to 30s for the transfer to take effect on any pod we can reach.
DEADLINE=$(( SECONDS + 30 ))
NEW_LEADER=""
while (( SECONDS < DEADLINE )); do
  for i in 0 1 2; do
    LOCAL=$(( HTTP_PORT + 20 + i ))
    PID=$(pf_start "$i" "$LOCAL")
    if pf_wait "$LOCAL" 5; then
      L=$(api "$LOCAL" GET /api/v1/cluster | jq -r '.leaderId // empty' 2>/dev/null || echo "")
      pf_stop "$PID"
      if [[ "$L" == "$TARGET_PEER" ]]; then
        NEW_LEADER="$L"
        break 2
      fi
    else
      pf_stop "$PID"
    fi
  done
  sleep 2
done

[[ "$NEW_LEADER" == "$TARGET_PEER" ]] || {
  echo "ERROR: leadership did not transfer; got '${NEW_LEADER:-<none>}'"
  exit 1
}
echo "    New leader: $NEW_LEADER"

# Verify writes via the new leader.
NEW_LEADER_ORDINAL=$(echo "$NEW_LEADER" | sed -nE "s/^${RELEASE}-([0-9]+)\..*$/\1/p")
PF_PID=$(pf_start "$NEW_LEADER_ORDINAL" "$HTTP_PORT")
pf_wait "$HTTP_PORT" || { echo "ERROR: port-forward to new leader failed"; exit 1; }

api "$HTTP_PORT" POST /api/v1/command/integration-test \
  '{"language":"sql","command":"INSERT INTO TestDoc SET name = '\''post-transfer'\''"}' \
  >/dev/null

POST_RESULT=$(api "$HTTP_PORT" POST /api/v1/query/integration-test \
  '{"language":"sql","command":"SELECT name FROM TestDoc WHERE name = '\''post-transfer'\''"}' \
  | jq -r '.result[0].name // empty')

pf_stop "$PF_PID"

[[ "$POST_RESULT" == "post-transfer" ]] || {
  echo "ERROR: write via new leader failed (got '${POST_RESULT:-<empty>}')"
  exit 1
}
echo "    Write via new leader succeeded."

# Update tracked leader for downstream phases.
LEADERS[0]=$NEW_LEADER
LEADER_ORDINAL=$NEW_LEADER_ORDINAL

# ── phase 7: scale-up 3 -> 5 ──────────────────────────────────────────────────

echo "==> [7/8] Scaling cluster from 3 to 5 replicas..."
helm upgrade "$RELEASE" charts/arcadedb/ \
  --reuse-values \
  --set replicaCount=5 \
  --wait --timeout 5m

kubectl rollout status statefulset/"$RELEASE" \
  -n "$NAMESPACE" --timeout=5m
echo "    Rollout complete (5 pods Ready)."

echo "    Re-checking quorum across 5 pods..."
assert_quorum_n 5 || exit 1

echo "    Re-asserting STATUS across all peers..."
PF_PID=$(pf_start "$LEADER_ORDINAL" "$HTTP_PORT")
pf_wait "$HTTP_PORT" || { echo "ERROR: port-forward to leader failed"; exit 1; }

PEER_COUNT=$(api "$HTTP_PORT" GET /api/v1/cluster | jq '.peers | length')
[[ "$PEER_COUNT" == "5" ]] || {
  echo "ERROR: expected 5 peers in cluster status, got ${PEER_COUNT}"
  exit 1
}

cluster_status_assert_healthy "$HTTP_PORT" || exit 1

pf_stop "$PF_PID"

# ── phase 8: snapshot-install recovery ────────────────────────────────────────

echo "==> [8/8] Snapshot-install on follower recovery..."

PF_PID=$(pf_start "$LEADER_ORDINAL" "$HTTP_PORT")
pf_wait "$HTTP_PORT" || { echo "ERROR: port-forward to leader failed"; exit 1; }

echo "    Writing 100 rows to push log past snapshotThreshold=50..."
for i in $(seq 1 100); do
  api "$HTTP_PORT" POST /api/v1/command/integration-test \
    "{\"language\":\"sql\",\"command\":\"INSERT INTO TestDoc SET name = 'snap-${i}'\"}" \
    >/dev/null
done
echo "    Wrote 100 rows."

# Pick a non-leader pod ordinal to delete.
DELETE_ORDINAL=""
for i in 0 1 2 3 4; do
  if [[ "$i" != "$LEADER_ORDINAL" ]]; then
    DELETE_ORDINAL=$i
    break
  fi
done
[[ -n "$DELETE_ORDINAL" ]] || { echo "ERROR: no non-leader pod to delete"; exit 1; }

pf_stop "$PF_PID"

echo "    Deleting pod ${RELEASE}-${DELETE_ORDINAL}..."
kubectl delete pod "${RELEASE}-${DELETE_ORDINAL}" -n "$NAMESPACE" --wait=false
kubectl wait --for=condition=Ready pod/"${RELEASE}-${DELETE_ORDINAL}" \
  -n "$NAMESPACE" --timeout=2m
echo "    Pod recreated and Ready."

PF_PID=$(pf_start "$LEADER_ORDINAL" "$HTTP_PORT")
pf_wait "$HTTP_PORT" || { echo "ERROR: port-forward to leader failed"; exit 1; }

DEADLINE=$(( SECONDS + 90 ))
RECOVERED=0
LAST_STATUS=""
while (( SECONDS < DEADLINE )); do
  STATUS_JSON=$(api "$HTTP_PORT" GET /api/v1/cluster)
  S=$(echo "$STATUS_JSON" \
    | jq -r --arg p "${RELEASE}-${DELETE_ORDINAL}" \
      '.peers[] | select(.id | startswith($p)) | .status // empty')
  if [[ "$S" == "HEALTHY" ]]; then
    RECOVERED=1
    break
  fi
  if [[ -z "$S" ]]; then
    HAS_STATUS_FIELD=$(echo "$STATUS_JSON" | jq -r '.peers[0].status // empty')
    if [[ -z "$HAS_STATUS_FIELD" ]]; then
      PEER_PRESENT=$(echo "$STATUS_JSON" \
        | jq -r --arg p "${RELEASE}-${DELETE_ORDINAL}" \
          '.peers[] | select(.id | startswith($p)) | .id' | head -n1)
      if [[ -n "$PEER_PRESENT" ]]; then
        echo "    NOTE: STATUS field absent on this image; peer is present in cluster, accepting as recovered."
        RECOVERED=1
        break
      fi
    fi
  fi
  LAST_STATUS=$S
  echo "    peer ${RELEASE}-${DELETE_ORDINAL} status=${S:-<absent>}, retrying..."
  sleep 5
done
pf_stop "$PF_PID"

(( RECOVERED )) || {
  echo "ERROR: recreated pod did not reach HEALTHY in 90s (last status: ${LAST_STATUS:-<absent>})"
  exit 1
}
echo "    Recreated pod recovered."

# Best-effort log signal: did the snapshot-install path actually run?
if kubectl logs "${RELEASE}-${DELETE_ORDINAL}" -n "$NAMESPACE" --tail=500 2>/dev/null \
     | grep -q SnapshotInstaller; then
  echo "    Confirmed snapshot-install path in logs."
else
  echo "    NOTE: SnapshotInstaller log line not found (log wording is not a stable contract; not a failure)."
fi

echo "==> All checks passed."
