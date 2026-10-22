#!/usr/bin/env bash
set -euo pipefail

RELEASE=test-arcadedb
NAMESPACE=default
HTTP_PORT=2480
RAFT_TIMEOUT=60
ROLLOUT_TIMEOUT=120
# image.flavor the chart was installed with (jvm|native).
IMAGE_FLAVOR=${IMAGE_FLAVOR:-jvm}
# replicaCount the chart was installed with. 1 = a single node: no HA, no cluster
# token, and the Raft phases (3, 6, 7, 12) are skipped.
REPLICAS=${REPLICAS:-3}
[[ "$REPLICAS" =~ ^[1-9][0-9]*$ ]] || {
  echo "ERROR: REPLICAS must be a positive integer (got '${REPLICAS}')"; exit 1; }
# Secret and key the root password was installed from. Empty name = the
# chart-generated arcadedb-credentials-secret, which also carries clusterToken.
ROOT_PASSWORD_SECRET=${ROOT_PASSWORD_SECRET:-}
ROOT_PASSWORD_KEY=${ROOT_PASSWORD_KEY:-}
# Secret and key of a user-supplied HA cluster token
# (arcadedb.credentials.clusterToken.secret.*). Empty name = none.
CLUSTER_TOKEN_SECRET=${CLUSTER_TOKEN_SECRET:-}
CLUSTER_TOKEN_KEY=${CLUSTER_TOKEN_KEY:-clusterToken}
# How the chart is expected to hand the root password to the server:
#   file - -Darcadedb.server.rootPasswordPath, plus -Darcadedb.ha.clusterTokenPath
#          when a token is mounted (see EXPECT_TOKEN_SECRET below). In HA with a
#          user-supplied Secret and no token this needs an image >= 26.11.1.
#   env  - the arcadedb.server.rootPassword env var: HA on an image older than
#          26.11.1 with a user-supplied Secret and no cluster token (issue #45)
ROOT_PASSWORD_FROM=${ROOT_PASSWORD_FROM:-file}
case "$ROOT_PASSWORD_FROM" in
  file) ;;
  env)
    [[ -n "$ROOT_PASSWORD_SECRET" && -n "$ROOT_PASSWORD_KEY" ]] || {
      echo "ERROR: ROOT_PASSWORD_FROM=env needs ROOT_PASSWORD_SECRET and ROOT_PASSWORD_KEY"
      exit 1
    }
    if [[ -n "$CLUSTER_TOKEN_SECRET" ]] || (( REPLICAS == 1 )); then
      echo "ERROR: ROOT_PASSWORD_FROM=env is only chosen in HA (REPLICAS > 1) without a cluster token"
      exit 1
    fi ;;
  *) echo "ERROR: ROOT_PASSWORD_FROM must be 'file' or 'env' (got '${ROOT_PASSWORD_FROM}')"; exit 1 ;;
esac
# The cluster token Secret the chart is expected to mount, mirroring
# arcadedb.credentials.mountClusterToken: only in HA, and then the user-supplied
# token, else the generated key unless a user root password Secret made it opt-in.
EXPECT_TOKEN_SECRET=""
EXPECT_TOKEN_KEY=""
if (( REPLICAS > 1 )); then
  if [[ -n "$CLUSTER_TOKEN_SECRET" ]]; then
    EXPECT_TOKEN_SECRET=$CLUSTER_TOKEN_SECRET
    EXPECT_TOKEN_KEY=$CLUSTER_TOKEN_KEY
  elif [[ -z "$ROOT_PASSWORD_SECRET" ]]; then
    EXPECT_TOKEN_SECRET=arcadedb-credentials-secret
    EXPECT_TOKEN_KEY=clusterToken
  fi
fi

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

assert_health_204() {   # assert_health_204 <local-port>
  local port=$1 code
  code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 \
    "http://localhost:${port}/api/v1/health" || true)
  if [[ "$code" != "204" ]]; then
    echo "ERROR: /api/v1/health returned ${code}, expected 204"
    return 1
  fi
  echo "    /api/v1/health -> 204 (unauthenticated liveness OK)"
  return 0
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

# jq rather than jsonpath: a user-supplied key may contain dots.
PASSWORD_SECRET=${ROOT_PASSWORD_SECRET:-arcadedb-credentials-secret}
PASSWORD_KEY=${ROOT_PASSWORD_KEY:-rootPassword}
PASSWORD=$(kubectl get secret "$PASSWORD_SECRET" -n "$NAMESPACE" -o json \
  | jq -r --arg k "$PASSWORD_KEY" '.data[$k] // empty' | base64 -d)

[[ -n "$PASSWORD" ]] || {
  echo "ERROR: key ${PASSWORD_KEY} of secret ${PASSWORD_SECRET} is empty or missing"; exit 1; }

# ── phase 1: pod readiness ────────────────────────────────────────────────────

echo "==> [1/12] Waiting for StatefulSet rollout (timeout ${ROLLOUT_TIMEOUT}s)..."
kubectl rollout status statefulset/"$RELEASE" \
  -n "$NAMESPACE" --timeout="${ROLLOUT_TIMEOUT}s"
echo "    All ${REPLICAS} pods Ready."

# ── phase 2: liveness health probe ────────────────────────────────────────────

echo "==> [2/12] Asserting /api/v1/health liveness endpoint..."
PF_PID=$(pf_start 0 "$HTTP_PORT")
pf_wait "$HTTP_PORT" || { echo "ERROR: port-forward to pod-0 failed"; exit 1; }
assert_health_204 "$HTTP_PORT" || exit 1
pf_stop "$PF_PID"

# ── phase 3: raft formation ───────────────────────────────────────────────────

if (( REPLICAS == 1 )); then
  # No Raft group: the only pod takes the writes the later phases send "to the leader".
  echo "==> [3/12] Skipped: a single node forms no Raft group."
  LEADER_ORDINAL=0
else
  echo "==> [3/12] Checking Raft leader consensus (timeout ${RAFT_TIMEOUT}s)..."
  assert_quorum_n "$REPLICAS" || exit 1
fi

# ── phase 4: write ────────────────────────────────────────────────────────────

# LEADER_ORDINAL is set by assert_quorum_n above.

echo "==> [4/12] Writing test data via leader pod-${LEADER_ORDINAL}..."
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

# ── phase 5: read and assert ──────────────────────────────────────────────────

echo "==> [5/12] Reading back test data..."
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

# ── phase 6: STATUS column ────────────────────────────────────────────────────

if (( REPLICAS == 1 )); then
  echo "==> [6/12] Skipped: a single node has no Raft peers."
  echo "==> [7/12] Skipped: a single node has no leadership to transfer."
else
  echo "==> [6/12] Asserting STATUS=HEALTHY for all peers..."
  PF_PID=$(pf_start "$LEADER_ORDINAL" "$HTTP_PORT")
  pf_wait "$HTTP_PORT" || { echo "ERROR: port-forward to leader failed"; exit 1; }

  cluster_status_assert_healthy "$HTTP_PORT" || exit 1

  pf_stop "$PF_PID"

  # ── phase 7: leadership transfer ──────────────────────────────────────────────

  echo "==> [7/12] Transferring Raft leadership..."
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
    for (( i=0; i<REPLICAS; i++ )); do
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
fi

# ── phase 8: console history under readOnlyRootFilesystem (issue #22) ─────────

if [[ "$IMAGE_FLAVOR" == "native" ]]; then
  # The native image has no shell and no bin/console.sh, and the chart sets no
  # ARCADEDB_SETTINGS for it, so there is nothing for this phase to exercise.
  echo "==> [8/12] Skipped: the native image has no shell or console."
else
  echo "==> [8/12] Asserting the console can write its history file..."
  POD="${RELEASE}-0"

  # bin/console.sh asks JLine for the relative history file ".history", resolved
  # against the JVM working directory. The chart moves that directory to a writable
  # volume through ARCADEDB_SETTINGS; without it the console writes into the
  # read-only image install directory and warns on every command.
  CONSOLE_SETTINGS=$(kubectl exec -n "$NAMESPACE" "$POD" -- \
    sh -c 'printf %s "${ARCADEDB_SETTINGS:-}"')

  case "$CONSOLE_SETTINGS" in
    *-Duser.dir=*) ;;
    *) echo "ERROR: ARCADEDB_SETTINGS carries no -Duser.dir (got '${CONSOLE_SETTINGS:-<unset>}')"
       exit 1 ;;
  esac

  CONSOLE_DIR=${CONSOLE_SETTINGS##*-Duser.dir=}
  CONSOLE_DIR=${CONSOLE_DIR%% *}
  echo "    Console working directory: ${CONSOLE_DIR}"

  # The exec session is the console's launch context, so probe from there.
  kubectl exec -n "$NAMESPACE" "$POD" -- \
    sh -c "cd '${CONSOLE_DIR}' && touch .history && rm -f .history" || {
    echo "ERROR: ${CONSOLE_DIR}/.history is not writable - the console would fail to save history"
    exit 1
  }
  echo "    ${CONSOLE_DIR}/.history is writable."

  # The default working directory (image WORKDIR) must stay read-only: that is the
  # hardening this phase exists to keep honest.
  if kubectl exec -n "$NAMESPACE" "$POD" -- \
       sh -c 'touch .history-probe 2>/dev/null && rm -f .history-probe' 2>/dev/null; then
    echo "    WARNING: the image install directory is writable; readOnlyRootFilesystem is off."
  else
    echo "    Image install directory is read-only, as expected."
  fi

  # The server process keeps the working directory it has always had, so its own
  # relative path resolution (config/, backups/) is untouched by the console fix.
  kubectl exec -n "$NAMESPACE" "$POD" -- \
    sh -c 'tr "\0" "\n" </proc/1/cmdline' | grep -qx -- "-Duser.dir=/home/arcadedb" || {
    echo "ERROR: server process is not pinned to -Duser.dir=/home/arcadedb"
    exit 1
  }
  echo "    Server process pinned to /home/arcadedb."

  # Finally, the console itself must still start with those settings applied.
  CONSOLE_OUT=$(kubectl exec -n "$NAMESPACE" "$POD" -- bin/console.sh "help" 2>&1) || {
    echo "ERROR: bin/console.sh failed to run inside the pod"
    echo "$CONSOLE_OUT"
    exit 1
  }
  echo "    bin/console.sh runs inside the pod."
fi

# ── phase 9: credentials stay off the command line (issues #35, #45) ─────────

# The cluster just formed quorum (phase 3) with these settings, and every pod
# accepted the root password from the Secret (assert_quorum_n logs in to each),
# so the server read the password the way the chart handed it over. What is left
# is to check that it took the expected route and that no secret reaches the
# process arguments, readable through /proc/<pid>/cmdline.
if [[ "$IMAGE_FLAVOR" == "native" ]]; then
  # No shell in the native image to read /proc from; the pod spec is checked instead.
  echo "==> [9/12] Asserting credentials stay off the command line (pod spec, native image)..."
  CMDLINE=$(kubectl get pod -n "$NAMESPACE" "${RELEASE}-0" \
    -o jsonpath='{range .spec.containers[0].command[*]}{@}{"\n"}{end}')
else
  echo "==> [9/12] Asserting credentials stay off the command line..."
  CMDLINE=$(kubectl exec -n "$NAMESPACE" "${RELEASE}-0" -- \
    sh -c 'tr "\0" "\n" </proc/1/cmdline')
fi

if grep -q -- '^-Darcadedb.server.rootPassword=' <<<"$CMDLINE" \
   || grep -qF -- "$PASSWORD" <<<"$CMDLINE"; then
  echo "ERROR: the root password appears in the server's process arguments"
  exit 1
fi

if [[ "$ROOT_PASSWORD_FROM" == "env" ]]; then
  # Pre-26.11.1 HA fallback (#45): those servers derive the cluster token from the
  # arcadedb.server.rootPassword setting only, so the chart mounts no password or
  # token file and exports the setting as an env var named after its key. Phase 12
  # checks that the nodes derived matching tokens from it.
  if grep -q -- '^-Darcadedb.server.rootPasswordPath=' <<<"$CMDLINE" \
     || grep -q -- '^-Darcadedb.ha.clusterTokenPath=' <<<"$CMDLINE"; then
    echo "ERROR: expected the env-var fallback, but the server reads a password or token file;"
    echo "       is image.tag older than 26.11.1, and is no cluster token Secret set?"
    exit 1
  fi
  ENV_REF=$(kubectl get pod -n "$NAMESPACE" "${RELEASE}-0" -o json \
    | jq -r '.spec.containers[0].env[]? | select(.name == "arcadedb.server.rootPassword")
             | if .value != null then "literal value"
               else "\(.valueFrom.secretKeyRef.name // "")/\(.valueFrom.secretKeyRef.key // "")" end')
  if [[ "$ENV_REF" != "${ROOT_PASSWORD_SECRET}/${ROOT_PASSWORD_KEY}" ]]; then
    echo "ERROR: env var arcadedb.server.rootPassword should come from secret ${ROOT_PASSWORD_SECRET}/${ROOT_PASSWORD_KEY}, got '${ENV_REF:-<absent>}'"
    exit 1
  fi
  echo "    Root password passed as env var arcadedb.server.rootPassword from ${ENV_REF}; no file, not in the arguments."
else
  grep -q -- '^-Darcadedb.server.rootPasswordPath=' <<<"$CMDLINE" || {
    echo "ERROR: the server is not started with -Darcadedb.server.rootPasswordPath"; exit 1; }
  if kubectl get pod -n "$NAMESPACE" "${RELEASE}-0" -o json \
       | jq -e '.spec.containers[0].env[]? | select(.name == "arcadedb.server.rootPassword")' >/dev/null; then
    echo "ERROR: expected the password file, but the env var arcadedb.server.rootPassword is set too"
    exit 1
  fi

  if [[ -n "$EXPECT_TOKEN_SECRET" ]]; then
    # jq rather than jsonpath: a user-supplied key may contain dots.
    TOKEN=$(kubectl get secret "$EXPECT_TOKEN_SECRET" -n "$NAMESPACE" -o json \
      | jq -r --arg k "$EXPECT_TOKEN_KEY" '.data[$k] // empty' | base64 -d)
    [[ -n "$TOKEN" ]] || {
      echo "ERROR: key ${EXPECT_TOKEN_KEY} of secret ${EXPECT_TOKEN_SECRET} is empty or missing"; exit 1; }

    grep -q -- '^-Darcadedb.ha.clusterTokenPath=' <<<"$CMDLINE" || {
      echo "ERROR: the server is not started with -Darcadedb.ha.clusterTokenPath"; exit 1; }
    if grep -qF -- "$TOKEN" <<<"$CMDLINE"; then
      echo "ERROR: the cluster token appears in the server's process arguments"
      exit 1
    fi
    # The mounted token must be the expected Secret's, not the generated one.
    TOKEN_REF=$(kubectl get pod -n "$NAMESPACE" "${RELEASE}-0" -o json \
      | jq -r '[.spec.volumes[]?.projected.sources[]?.secret? // empty
                | select(any(.items[]?; .path == "clusterToken"))
                | "\(.name)/\(.items[] | select(.path == "clusterToken") | .key)"] | join(",")')
    if [[ "$TOKEN_REF" != "${EXPECT_TOKEN_SECRET}/${EXPECT_TOKEN_KEY}" ]]; then
      echo "ERROR: the clusterToken file should come from secret ${EXPECT_TOKEN_SECRET}/${EXPECT_TOKEN_KEY}, got '${TOKEN_REF:-<absent>}'"
      exit 1
    fi
    echo "    Root password and cluster token (${TOKEN_REF}) are read from files; neither is in the arguments."
  else
    # Single node, or HA with a user-supplied root password Secret and no token on
    # an image >= 26.11.1, which derives the token from the password file. Phase 12
    # checks that the HA nodes derived matching tokens from it.
    if grep -q -- '^-Darcadedb.ha.clusterTokenPath=' <<<"$CMDLINE"; then
      echo "ERROR: no cluster token Secret is configured, but the server reads -Darcadedb.ha.clusterTokenPath"
      exit 1
    fi
    echo "    Root password is read from a file and no cluster token file is mounted; nothing in the arguments."
  fi
fi

# ── phase 10: logging configuration is loaded (issue #38) ────────────────────

echo "==> [10/12] Asserting the server loaded the chart's logging configuration..."
POD="${RELEASE}-0"

# The arcadedb-config volume hides the image's config/arcadedb-log.properties.
# The chart mounts its own copy from a ConfigMap; if the server cannot find the
# file it names, it prints this line and falls back to a fixed ./log directory.
# Capture first: under pipefail, `kubectl logs | grep -q` fails on SIGPIPE when
# grep exits at the first match, which would hide exactly the line we look for.
POD_LOGS=$(kubectl logs -n "$NAMESPACE" "$POD")
if grep -q "Error on loading logging configuration" <<<"$POD_LOGS"; then
  echo "ERROR: the server did not find its logging configuration file:"
  grep "Error on loading logging configuration" <<<"$POD_LOGS"
  exit 1
fi
echo "    No logging configuration error at startup."

if [[ "$IMAGE_FLAVOR" == "native" ]]; then
  echo "    Log file check skipped: the native image has no shell."
else
  # The FileHandler pattern must follow arcadedb.logsDirectory (ARCADEDB_LOG_DIR).
  kubectl exec -n "$NAMESPACE" "$POD" -- \
    sh -c 'test -s "$ARCADEDB_LOG_DIR/arcadedb.log.0"' || {
    echo "ERROR: no arcadedb.log.0 in the configured logs directory"
    exit 1
  }
  echo "    Server log written to the configured logs directory."
fi

# ── phase 11: default config files are seeded (issues #39, #49) ─────────────

POD="${RELEASE}-0"
INIT_NAMES=$(kubectl get pod -n "$NAMESPACE" "$POD" \
  -o jsonpath='{.spec.initContainers[*].name}')
if [[ "$IMAGE_FLAVOR" == "native" ]]; then
  echo "==> [11/12] Asserting server-groups.json was seeded on the native image..."
  # The native image has no shell, so config-seed runs the JVM image of the same
  # version (#49), and the file cannot be read with kubectl exec. Check that the
  # init container ran the JVM image, that it left server-groups.json on the
  # volume, and that the server loaded the readonly group from it.
  if [[ " $INIT_NAMES " != *" config-seed "* ]]; then
    echo "ERROR: no config-seed init container on the native image; init containers: ${INIT_NAMES:-<none>}"
    exit 1
  fi
  SEED_IMAGE=$(kubectl get pod -n "$NAMESPACE" "$POD" \
    -o jsonpath='{.spec.initContainers[?(@.name=="config-seed")].image}')
  if [[ "$SEED_IMAGE" == *-native ]]; then
    echo "ERROR: config-seed runs the native image ${SEED_IMAGE}, which has no shell"
    exit 1
  fi
  echo "    config-seed ran ${SEED_IMAGE}."
  SEED_LOGS=$(kubectl logs -n "$NAMESPACE" "$POD" -c config-seed)
  if ! grep -qE 'config-seed: (seeded|keeping existing) server-groups.json' <<<"$SEED_LOGS"; then
    echo "ERROR: config-seed did not leave server-groups.json on the config volume:"
    echo "$SEED_LOGS"
    exit 1
  fi
  PF_PID=$(pf_start 0 "$HTTP_PORT")
  pf_wait "$HTTP_PORT" 20 || { echo "ERROR: port-forward to ${POD} never became ready"; exit 1; }
  GROUPS_JSON=$(api "$HTTP_PORT" GET /api/v1/server/groups) || {
    echo "ERROR: GET /api/v1/server/groups failed"; exit 1;
  }
  pf_stop "$PF_PID"
  if [[ "$(jq -r '.result.databases["*"].groups | has("readonly")' <<<"$GROUPS_JSON")" != "true" ]]; then
    echo "ERROR: the server has no readonly group; it did not load the seeded server-groups.json:"
    echo "$GROUPS_JSON" | jq '.result' || echo "$GROUPS_JSON"
    exit 1
  fi
  echo "    The server loaded the readonly group from the seeded server-groups.json."
else
  echo "==> [11/12] Asserting the image's server-groups.json was seeded..."
  # The arcadedb-config volume hides the image's config/. Without the seed the
  # server uses its built-in groups, which has no readonly group.
  # The CI install keeps the default arcadedb.configDirectory.
  kubectl exec -n "$NAMESPACE" "$POD" -- \
    grep -q '"readonly"' /home/arcadedb/config/server-groups.json || {
    echo "ERROR: server-groups.json has no readonly group; init containers: ${INIT_NAMES:-<none>}"
    kubectl logs -n "$NAMESPACE" "$POD" -c config-seed || true
    exit 1
  }
  echo "    server-groups.json holds the image's readonly group."
fi

# ── phase 12: write via a follower (issue #54) ──────────────────────────────

# A follower forwards the write to the leader, authenticating with the cluster
# token. In the env-var fallback every node derives that token from the root
# password setting, so this is where a node that failed to read it would show.
if (( REPLICAS == 1 )); then
  echo "==> [12/12] Skipped: a single node has no follower to forward through."
else
  FOLLOWER_ORDINAL=""
  for (( i=0; i<REPLICAS; i++ )); do
    [[ "$i" == "$LEADER_ORDINAL" ]] || { FOLLOWER_ORDINAL=$i; break; }
  done
  echo "==> [12/12] Writing via follower pod-${FOLLOWER_ORDINAL}, reading back on leader pod-${LEADER_ORDINAL}..."
  PF_PID=$(pf_start "$FOLLOWER_ORDINAL" "$HTTP_PORT")
  pf_wait "$HTTP_PORT" || { echo "ERROR: port-forward to follower pod-${FOLLOWER_ORDINAL} failed"; exit 1; }
  api "$HTTP_PORT" POST /api/v1/command/integration-test \
    '{"language":"sql","command":"INSERT INTO TestDoc SET name = '\''via-follower'\''"}' \
    >/dev/null || { echo "ERROR: write via follower pod-${FOLLOWER_ORDINAL} failed"; exit 1; }
  pf_stop "$PF_PID"

  PF_PID=$(pf_start "$LEADER_ORDINAL" "$HTTP_PORT")
  pf_wait "$HTTP_PORT" || { echo "ERROR: port-forward to leader pod-${LEADER_ORDINAL} failed"; exit 1; }
  FOLLOWER_RESULT=$(api "$HTTP_PORT" POST /api/v1/query/integration-test \
    '{"language":"sql","command":"SELECT name FROM TestDoc WHERE name = '\''via-follower'\''"}' \
    | jq -r '.result[0].name // empty') || FOLLOWER_RESULT=""
  pf_stop "$PF_PID"

  [[ "$FOLLOWER_RESULT" == "via-follower" ]] || {
    echo "ERROR: the write via follower pod-${FOLLOWER_ORDINAL} is not on the leader (got '${FOLLOWER_RESULT:-<empty>}')"
    exit 1
  }
  echo "    Write via follower reached the leader."
fi

# Two more phases, helm-upgrade scale-up 3->5 and snapshot-install recovery (once
# numbered 9 and 10, before phases 9 and 10 above took those numbers), were planned
# but discarded after CI proved the scenarios are not supported by the current
# ArcadeDB image: a `helm upgrade --set replicaCount=5` rolling-restarts
# all StatefulSet pods AND adds two with a serverList of 5 entries, but Raft
# does not auto-vote in the new peers (the support email confirms this requires
# an explicit POST /api/v1/cluster/peer call from the leader). The cluster ends
# up unable to re-form quorum after the rolling restart. The snapshot-install
# phase depended on the post-scale-up cluster, so it was dropped with the scale-up.
# See docs/superpowers/specs/2026-05-09-ha-integration-tests-design.md for the
# updated rationale.

echo "==> All checks passed."
