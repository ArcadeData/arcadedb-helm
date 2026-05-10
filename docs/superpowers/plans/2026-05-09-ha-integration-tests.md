# HA Integration Tests Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Extend `ci/integration-test.sh` with four new phases that exercise Raft HA scenarios from the support email Q&A: STATUS column observation, runtime leadership transfer, helm-upgrade scale-up 3→5, and snapshot-install recovery.

**Architecture:** Single CI job, single kind cluster, single Helm install. New phases append to the existing script in order of escalating risk; the destructive snapshot phase runs last. A small refactor extracts a generalized quorum helper so both the existing 3-pod and the new 5-pod check use the same code path.

**Tech Stack:** bash, kubectl, kind, helm, jq, curl. No new tooling.

**Spec:** `docs/superpowers/specs/2026-05-09-ha-integration-tests-design.md`

---

## Local Setup (before starting any task)

To exercise the integration script locally between tasks, you need a kind cluster with the chart installed. Run once before Task 2:

```bash
kind create cluster --wait 60s

helm install test-arcadedb charts/arcadedb/ \
  --set replicaCount=3 \
  --set persistence.enabled=false \
  --set arcadedb.defaultDatabases="" \
  --set 'arcadedb.extraCommands[1]=-Darcadedb.ha.snapshotThreshold=50' \
  --timeout 5m --wait
```

Tear down at the end (or between major iterations if needed):

```bash
kind delete cluster
```

After Task 7 the cluster will have 5 pods and a deleted-and-recreated peer; you may want to delete and recreate the cluster between full runs.

---

## Task 1: Add `snapshotThreshold` override to CI workflow

**Files:**
- Modify: `.github/workflows/lint.yml` (the `Install chart` step in the `integration` job)

- [ ] **Step 1: Update the helm install args in `lint.yml`**

Locate the `Install chart` step in the `integration` job. Replace its `run:` block with:

```yaml
      - name: Install chart
        run: |
          helm install test-arcadedb charts/arcadedb/ \
            --set replicaCount=3 \
            --set persistence.enabled=false \
            --set arcadedb.defaultDatabases="" \
            --set 'arcadedb.extraCommands[1]=-Darcadedb.ha.snapshotThreshold=50' \
            --timeout 5m \
            --wait
```

- [ ] **Step 2: Verify YAML is valid**

Run:

```bash
python3 -c "import yaml,sys; yaml.safe_load(open('.github/workflows/lint.yml'))" \
  && echo OK
```

Expected: `OK`

- [ ] **Step 3: Commit**

```bash
git add .github/workflows/lint.yml
git commit -m "ci: lower snapshot threshold for HA integration test"
```

---

## Task 2: Refactor — extract `assert_quorum_n` helper and renumber phase echoes

**Files:**
- Modify: `ci/integration-test.sh` (helpers section + phase 2 + all phase echoes)

The existing phase 2 hardcodes ordinals 0/1/2. The 5-pod scale-up in Task 6 needs the same logic for 0..4. Factor the loop out, parametrized by pod count. While we're here, update the `[N/4]` phase counters to `[N/8]` so subsequent tasks just append.

- [ ] **Step 1: Add `assert_quorum_n` helper after the `cleanup` trap**

Insert after line 47 (after the `trap cleanup EXIT` line) in `ci/integration-test.sh`:

```bash
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
```

- [ ] **Step 2: Replace existing phase 2 body with a call to `assert_quorum_n`**

Replace the block from `echo "==> [2/4] Checking Raft leader consensus..."` through the end of its `while true; do ... done` loop (lines 66–96 in the current file) with:

```bash
# ── phase 2: raft formation ───────────────────────────────────────────────────

echo "==> [2/8] Checking Raft leader consensus (timeout ${RAFT_TIMEOUT}s)..."
assert_quorum_n 3 || exit 1
```

- [ ] **Step 3: Drop the now-unused `LEADER_ORDINAL=...` parse in phase 3**

In the current phase 3 (write block), `assert_quorum_n` already exports `LEADER_ORDINAL`. Remove the duplicate parse. Replace the lines:

```bash
LEADER_ORDINAL=$(echo "${LEADERS[0]}" | sed -nE "s/^${RELEASE}-([0-9]+)\..*$/\1/p")
[[ -n "$LEADER_ORDINAL" ]] || { echo "ERROR: could not parse ordinal from leader '${LEADERS[0]}'"; exit 1; }
```

with a single comment:

```bash
# LEADER_ORDINAL is set by assert_quorum_n above.
```

- [ ] **Step 4: Renumber phase counters from `/4` to `/8`**

Update the four existing `echo "==> [N/4] ..."` lines so they read `[1/8]`, `[2/8]`, `[3/8]`, `[4/8]` respectively. Phases 5–8 will be added in subsequent tasks.

- [ ] **Step 5: Syntax-check the script**

Run:

```bash
bash -n ci/integration-test.sh && echo OK
```

Expected: `OK`

- [ ] **Step 6: Run end-to-end against the local kind cluster**

Run:

```bash
make test-integration
```

Expected output (last line): `==> All checks passed.`

If `assert_quorum_n` does not converge, dump cluster state:

```bash
kubectl get pods,svc -n default
kubectl logs -l app=arcadedb -n default --tail=50
```

- [ ] **Step 7: Commit**

```bash
git add ci/integration-test.sh
git commit -m "test(integration): extract assert_quorum_n helper, renumber phases"
```

---

## Task 3: Add Phase 5 — `STATUS=HEALTHY` assertion

**Files:**
- Modify: `ci/integration-test.sh` (append phase 5 after the existing phase 4)

- [ ] **Step 1: Add a `cluster_status_assert_healthy` helper**

Append to the helpers section (immediately after `assert_quorum_n` from Task 2):

```bash
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
```

- [ ] **Step 2: Append phase 5 before the final `echo "==> All checks passed."` line**

Insert this block immediately above the existing final line `echo "==> All checks passed."` (which must remain the last line of the file):

```bash
# ── phase 5: STATUS column ────────────────────────────────────────────────────

echo "==> [5/8] Asserting STATUS=HEALTHY for all peers..."
PF_PID=$(pf_start "$LEADER_ORDINAL" "$HTTP_PORT")
pf_wait "$HTTP_PORT" || { echo "ERROR: port-forward to leader failed"; exit 1; }

cluster_status_assert_healthy "$HTTP_PORT" || exit 1

pf_stop "$PF_PID"
```

- [ ] **Step 3: Syntax-check the script**

Run:

```bash
bash -n ci/integration-test.sh && echo OK
```

Expected: `OK`

- [ ] **Step 4: Run end-to-end against the local kind cluster**

Run:

```bash
make test-integration
```

Expected output: a line starting with `==> [5/8] Asserting STATUS=HEALTHY` followed by either `All N peers HEALTHY/CATCHING_UP.` or the WARNING graceful-skip line, then `==> All checks passed.`

- [ ] **Step 5: Commit**

```bash
git add ci/integration-test.sh
git commit -m "test(integration): assert peers STATUS=HEALTHY (phase 5)"
```

---

## Task 4: Add Phase 6 — runtime leadership transfer

**Files:**
- Modify: `ci/integration-test.sh` (append phase 6 after phase 5)

- [ ] **Step 1: Append phase 6 before the final `echo "==> All checks passed."` line**

```bash
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
```

- [ ] **Step 2: Syntax-check**

```bash
bash -n ci/integration-test.sh && echo OK
```

Expected: `OK`

- [ ] **Step 3: Run end-to-end**

```bash
make test-integration
```

Expected: a `[6/8]` block reporting `New leader: <pod-id>` (different from the original) and `Write via new leader succeeded.`, followed by `==> All checks passed.`

If the API responds with 404 or 405 on `/api/v1/cluster/leader`, the deployed image does not yet expose this endpoint — capture the response body via `curl -v` and report; do not silently skip (this endpoint is the entire point of phase 6).

- [ ] **Step 4: Commit**

```bash
git add ci/integration-test.sh
git commit -m "test(integration): exercise runtime leadership transfer (phase 6)"
```

---

## Task 5: Add Phase 7 — `helm upgrade` scale-up 3→5

**Files:**
- Modify: `ci/integration-test.sh` (append phase 7 after phase 6)

- [ ] **Step 1: Append phase 7 before the final `echo "==> All checks passed."` line**

```bash
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
```

- [ ] **Step 2: Syntax-check**

```bash
bash -n ci/integration-test.sh && echo OK
```

Expected: `OK`

- [ ] **Step 3: Run end-to-end**

```bash
make test-integration
```

Expected: `[7/8] Scaling cluster from 3 to 5 replicas...`, then `Rollout complete (5 pods Ready).`, `Raft leader: ... (pod-N)` (from `assert_quorum_n 5`), peer-count check passes, STATUS check passes, `==> All checks passed.`

If the rolling restart times out: increase `--timeout` to 10m and re-run; also check `kubectl describe pod test-arcadedb-3 -n default` for scheduling failures (kind clusters have limited resources).

- [ ] **Step 4: Commit**

```bash
git add ci/integration-test.sh
git commit -m "test(integration): scale-up 3->5 via helm upgrade (phase 7)"
```

---

## Task 6: Add Phase 8 — snapshot-install recovery

**Files:**
- Modify: `ci/integration-test.sh` (append phase 8 after phase 7)

- [ ] **Step 1: Append phase 8 before the final `echo "==> All checks passed."` line**

```bash
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
```

- [ ] **Step 2: Syntax-check**

```bash
bash -n ci/integration-test.sh && echo OK
```

Expected: `OK`

- [ ] **Step 3: Run end-to-end**

```bash
make test-integration
```

Expected: `[8/8] Snapshot-install on follower recovery...` block ending with `Recreated pod recovered.`, then `==> All checks passed.`

If the recreated pod does not reach HEALTHY in 90s, capture diagnostics:

```bash
kubectl logs "test-arcadedb-${DELETE_ORDINAL}" -n default --tail=200
kubectl logs "test-arcadedb-${LEADER_ORDINAL}" -n default --tail=200 | grep -i snapshot
```

If you see only `Snapshot download attempt N/3 failed` lines: the snapshot transfer is failing in the cluster, which is itself a real bug worth reporting; do not paper over it.

- [ ] **Step 4: Commit**

```bash
git add ci/integration-test.sh
git commit -m "test(integration): snapshot-install on follower recovery (phase 8)"
```

---

## Task 7: End-to-end CI verification

**Files:**
- No code changes; this task is pure verification.

- [ ] **Step 1: Push the branch and trigger CI**

```bash
git push -u origin "$(git rev-parse --abbrev-ref HEAD)"
```

- [ ] **Step 2: Watch the `integration` job in GitHub Actions**

Run:

```bash
gh run watch
```

Or open the Actions tab in the repo. The `integration` job should complete inside the 20-minute timeout and the log should contain all eight `[N/8]` phase headers ending with `==> All checks passed.`

- [ ] **Step 3: If CI fails on a phase that passed locally**

Common causes:
- kind in CI is slower than local; bump per-phase timeouts (`RAFT_TIMEOUT`, the 90s in phase 8) before flagging as a real bug.
- Image tag pulled in CI may differ from local cache; check the resolved tag in the `Install chart` step's helm output.

If a flake is intermittent specifically in phase 8, gate it behind an env var:

```bash
if [[ "${RUN_SNAPSHOT_TEST:-1}" != "0" ]]; then
  # phase 8 body
fi
```

This is the contingency from the spec's risk section; only apply it after observing real flake.

- [ ] **Step 4: Open PR**

Once CI is green:

```bash
gh pr create --fill
```

---

## Acceptance Checklist

- [ ] All 8 phases pass locally on an image tag that exposes the STATUS field.
- [ ] On older image tags, P5/P7 emit the WARNING graceful-skip line and the rest of the run still passes.
- [ ] CI completes inside the 20-minute timeout.
- [ ] No duplicated port-forward/poll loops between phase 2 and phase 7 — both go through `assert_quorum_n`.
- [ ] No dangling `PF_PID` background processes after the script exits (the existing `cleanup` trap covers this).
