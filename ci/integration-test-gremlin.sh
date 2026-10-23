#!/usr/bin/env bash
# Gremlin on a non-default port through arcadedb.plugins.gremlin.writePortToConfig
# (issue #62, follow-up to #58), against a real pod.
#
# Expects a release installed with:
#   arcadedb.plugins.gremlin.enabled=true
#   arcadedb.plugins.gremlin.port=$GREMLIN_PORT
#   arcadedb.plugins.gremlin.writePortToConfig=true
# and a single replica (the suite looks at pod 0 only). It then runs
# `helm upgrade --reuse-values` to move the port to $GREMLIN_UPGRADE_PORT, so it
# changes the release: run it last, and reinstall before running it again.
#
# Checks, on each port:
#   - config-seed ran with readOnlyRootFilesystem and logged the port it wrote;
#   - gremlin-server.yaml on the config volume carries that port;
#   - the server started the Gremlin plugin, which listens on that port and no
#     longer on the previous one (the server log does not name the port: TinkerPop
#     logs through SLF4J, which has no binding in the image);
#   - a TCP connect from another pod to <release>:<port> through the Service works.
set -euo pipefail

RELEASE=${RELEASE:-test-arcadedb}
NAMESPACE=${NAMESPACE:-default}
CHART_DIR=${CHART_DIR:-charts/arcadedb}
ROLLOUT_TIMEOUT=${ROLLOUT_TIMEOUT:-180}
GREMLIN_PORT=${GREMLIN_PORT:-8183}
GREMLIN_UPGRADE_PORT=${GREMLIN_UPGRADE_PORT:-$(( GREMLIN_PORT + 1 ))}
POD="${RELEASE}-0"
PROBE="${RELEASE}-gremlin-probe"

for p in "$GREMLIN_PORT" "$GREMLIN_UPGRADE_PORT"; do
  if ! [[ "$p" =~ ^[1-9][0-9]*$ ]] || (( p > 65535 )); then
    echo "ERROR: Gremlin ports must be TCP ports (got '${p}')"; exit 1
  fi
done
[[ "$GREMLIN_PORT" != "$GREMLIN_UPGRADE_PORT" ]] || {
  echo "ERROR: GREMLIN_UPGRADE_PORT must differ from GREMLIN_PORT (${GREMLIN_PORT})"; exit 1; }

# shellcheck source=ci/gremlin-lib.sh
source "$(dirname "$0")/gremlin-lib.sh"
trap cleanup EXIT

# check_port <phase-label> <port> <port-that-must-be-closed|"">
check_port() {
  local label=$1 port=$2 old=$3 seeded

  echo "==> [${label}a] config-seed ran under readOnlyRootFilesystem and wrote port ${port}..."
  seeded=$(kubectl get pod -n "$NAMESPACE" "$POD" -o json | jq -r \
    '.spec.initContainers[] | select(.name=="config-seed") | .securityContext.readOnlyRootFilesystem')
  [[ "$seeded" == "true" ]] || {
    echo "ERROR: config-seed is not on a read-only root filesystem (readOnlyRootFilesystem=${seeded:-<unset>})"
    exit 1
  }
  # Logs are read into a variable first: under pipefail, grep -q closing the pipe
  # early can fail kubectl with SIGPIPE on a long log.
  SEED_LOG=$(kubectl logs -n "$NAMESPACE" "$POD" -c config-seed)
  grep -qxF "config-seed: set port: ${port} in gremlin-server.yaml" <<<"$SEED_LOG" || {
    echo "ERROR: config-seed did not log 'config-seed: set port: ${port} in gremlin-server.yaml'"
    dump_pod; exit 1
  }
  echo "    config-seed: set port: ${port} in gremlin-server.yaml"

  echo "==> [${label}b] gremlin-server.yaml on the config volume carries port: ${port}..."
  # Exactly one top-level port: key, and it is the chart's value.
  PORT_LINES=$(kubectl exec -n "$NAMESPACE" "$POD" -c arcadedb -- \
    grep -E '^port[[:space:]]*:' /home/arcadedb/config/gremlin-server.yaml || true)
  [[ "$PORT_LINES" == "port: ${port}" ]] || {
    echo "ERROR: expected the single line 'port: ${port}', got: '${PORT_LINES:-<none>}'"
    dump_pod; exit 1
  }
  echo "    ${PORT_LINES}"

  echo "==> [${label}c] The Gremlin plugin started and listens on ${port}..."
  assert_plugin_started
  assert_listening "$port" "$old"

  echo "==> [${label}d] TCP connect to ${RELEASE}:${port} through the Service..."
  assert_service_connect "$port"
}

# ── phase 1: rollout ─────────────────────────────────────────────────────────

echo "==> [1/4] Waiting for StatefulSet rollout (timeout ${ROLLOUT_TIMEOUT}s)..."
kubectl rollout status statefulset/"$RELEASE" -n "$NAMESPACE" --timeout="${ROLLOUT_TIMEOUT}s"

start_probe

# ── phase 2: the installed port ──────────────────────────────────────────────

check_port 2/4 "$GREMLIN_PORT" ""

# ── phase 3: helm upgrade to another port ────────────────────────────────────

echo "==> [3/4] helm upgrade arcadedb.plugins.gremlin.port=${GREMLIN_UPGRADE_PORT}..."
OLD_UID=$(kubectl get pod -n "$NAMESPACE" "$POD" -o jsonpath='{.metadata.uid}')
helm upgrade "$RELEASE" "$CHART_DIR" -n "$NAMESPACE" --reuse-values \
  --set arcadedb.plugins.gremlin.port="$GREMLIN_UPGRADE_PORT" \
  --timeout "${ROLLOUT_TIMEOUT}s" --wait >/dev/null
kubectl rollout status statefulset/"$RELEASE" -n "$NAMESPACE" --timeout="${ROLLOUT_TIMEOUT}s"
NEW_UID=$(kubectl get pod -n "$NAMESPACE" "$POD" -o jsonpath='{.metadata.uid}')
[[ "$NEW_UID" != "$OLD_UID" ]] || {
  echo "ERROR: ${POD} was not replaced by the upgrade (uid ${OLD_UID})"; exit 1; }
echo "    ${POD} rolled."

# ── phase 4: the upgraded port ───────────────────────────────────────────────

check_port 4/4 "$GREMLIN_UPGRADE_PORT" "$GREMLIN_PORT"

echo "==> All Gremlin port checks passed."
