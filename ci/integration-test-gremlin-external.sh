#!/usr/bin/env bash
# Gremlin on a port set by the user's own gremlin-server.yaml, with
# arcadedb.plugins.gremlin.portManagedExternally (issue #66, follow-up to #52 and
# #62), against a real pod. The chart's port then only drives the Services and
# the NetworkPolicy; nothing in the chart moves the plugin.
#
# Expects a release installed with:
#   arcadedb.plugins.gremlin.enabled=true
#   arcadedb.plugins.gremlin.port=$GREMLIN_PORT
#   arcadedb.plugins.gremlin.portManagedExternally=true
# a single replica (the suite looks at pod 0 only) and the config directory on a
# volume that outlives the pod (persistence.config, on by default). It writes
# gremlin-server.yaml on that volume and restarts the pod, then runs
# `helm upgrade --reuse-values`, so it changes the release: run it last, and
# reinstall before running it again.
#
# The user's file reaches the server two ways, and the suite checks both:
#   - on the config volume (phases 2-3): config-seed must keep it as it is;
#   - from a ConfigMap mounted on <configDirectory>/gremlin-server.yaml through
#     volumeMounts (phase 4, on $GREMLIN_UPGRADE_PORT): the server reads the
#     mount, not the copy config-seed sees on the volume.
# On each: config-seed keeps the file and sets no port, the Gremlin plugin
# listens on the file's port and not on the previous one, and a pod reaches it
# through the Service.
set -euo pipefail

RELEASE=${RELEASE:-test-arcadedb}
NAMESPACE=${NAMESPACE:-default}
CHART_DIR=${CHART_DIR:-charts/arcadedb}
ROLLOUT_TIMEOUT=${ROLLOUT_TIMEOUT:-180}
CONFIG_DIR=${CONFIG_DIR:-/home/arcadedb/config}
GREMLIN_PORT=${GREMLIN_PORT:-8185}
GREMLIN_UPGRADE_PORT=${GREMLIN_UPGRADE_PORT:-$(( GREMLIN_PORT + 1 ))}
# The plugin's port when gremlin-server.yaml sets none (the image's file sets none).
DEFAULT_PORT=8182
POD="${RELEASE}-0"
PROBE="${RELEASE}-gremlin-probe"
CONFIGMAP="${RELEASE}-gremlin-server-yaml"
YAML="${CONFIG_DIR}/gremlin-server.yaml"

for p in "$GREMLIN_PORT" "$GREMLIN_UPGRADE_PORT"; do
  if ! [[ "$p" =~ ^[1-9][0-9]*$ ]] || (( p > 65535 )); then
    echo "ERROR: Gremlin ports must be TCP ports (got '${p}')"; exit 1
  fi
  [[ "$p" != "$DEFAULT_PORT" ]] || {
    echo "ERROR: Gremlin ports must differ from the plugin default ${DEFAULT_PORT}"; exit 1; }
done
[[ "$GREMLIN_PORT" != "$GREMLIN_UPGRADE_PORT" ]] || {
  echo "ERROR: GREMLIN_UPGRADE_PORT must differ from GREMLIN_PORT (${GREMLIN_PORT})"; exit 1; }

# shellcheck source=ci/gremlin-lib.sh
source "$(dirname "$0")/gremlin-lib.sh"
WORK=$(mktemp -d)
trap 'cleanup; rm -rf "$WORK"' EXIT

# with_port <port> < yaml > yaml: the same file with its top-level port: set to
# <port> (appended when it has none), as an operator would edit it.
with_port() {
  awk -v port="$1" '
    /^port[[:space:]]*:/ { if (!done) print "port: " port; done = 1; next }
    { print }
    END { if (!done) print "port: " port }'
}

volume_yaml() {   # the gremlin-server.yaml on the config volume, from config-seed's side
  kubectl exec -n "$NAMESPACE" "$POD" -c arcadedb -- cat "$YAML"
}

port_lines() {   # port_lines: the top-level port: lines of the file the server reads
  kubectl exec -n "$NAMESPACE" "$POD" -c arcadedb -- grep -E '^port[[:space:]]*:' "$YAML" || true
}

# assert_seed_kept <label>: config-seed kept gremlin-server.yaml and set no port.
assert_seed_kept() {
  local label=$1 env
  echo "==> [${label}] config-seed kept gremlin-server.yaml and set no port..."
  env=$(kubectl get pod -n "$NAMESPACE" "$POD" -o json | jq -r \
    '.spec.initContainers[] | select(.name=="config-seed") | [.env[]?.name] | join(",")')
  [[ ",${env}," != *",GREMLIN_PORT,"* ]] || {
    echo "ERROR: config-seed has GREMLIN_PORT set: portManagedExternally must not write the port"
    exit 1
  }
  SEED_LOG=$(kubectl logs -n "$NAMESPACE" "$POD" -c config-seed)
  grep -qxF "config-seed: keeping existing gremlin-server.yaml" <<<"$SEED_LOG" || {
    echo "ERROR: config-seed did not log 'config-seed: keeping existing gremlin-server.yaml'"
    dump_pod; exit 1
  }
  if grep -qF "set port:" <<<"$SEED_LOG"; then
    echo "ERROR: config-seed logged a 'set port:' line"
    dump_pod; exit 1
  fi
  echo "    config-seed: keeping existing gremlin-server.yaml"
}

# ── phase 1: first boot, before the user's file ──────────────────────────────

echo "==> [1/4] Waiting for StatefulSet rollout (timeout ${ROLLOUT_TIMEOUT}s)..."
kubectl rollout status statefulset/"$RELEASE" -n "$NAMESPACE" --timeout="${ROLLOUT_TIMEOUT}s"
start_probe

# The chart's port alone does not move the plugin: the volume holds the image's
# gremlin-server.yaml, which sets no port, so the plugin is on its default.
echo "    The Gremlin plugin is still on ${DEFAULT_PORT}: the chart's port does not move it..."
assert_plugin_started
assert_listening "$DEFAULT_PORT" "$GREMLIN_PORT"

# ── phase 2: the user's own gremlin-server.yaml on the config volume ─────────

echo "==> [2/4] Write gremlin-server.yaml with port: ${GREMLIN_PORT} on the config volume, restart ${POD}..."
volume_yaml > "$WORK/image.yaml"
[[ -z "$(grep -E '^port[[:space:]]*:' "$WORK/image.yaml" || true)" ]] || {
  echo "ERROR: the seeded gremlin-server.yaml already sets port:, phase 1 proves nothing"; exit 1; }
with_port "$GREMLIN_PORT" < "$WORK/image.yaml" > "$WORK/user.yaml"
kubectl exec -i -n "$NAMESPACE" "$POD" -c arcadedb -- \
  sh -c "cat > '${YAML}.new' && mv '${YAML}.new' '${YAML}'" < "$WORK/user.yaml"
volume_yaml > "$WORK/written.yaml"
cmp -s "$WORK/user.yaml" "$WORK/written.yaml" || {
  echo "ERROR: gremlin-server.yaml on the volume is not the file just written"; exit 1; }
restart_pod

# ── phase 3: the plugin binds the port the volume's file sets ────────────────

assert_seed_kept 3/4a

echo "==> [3/4b] gremlin-server.yaml on the volume is the user's file, byte for byte..."
volume_yaml > "$WORK/after.yaml"
cmp -s "$WORK/user.yaml" "$WORK/after.yaml" || {
  echo "ERROR: config-seed changed gremlin-server.yaml:"
  diff "$WORK/user.yaml" "$WORK/after.yaml" || true
  dump_pod; exit 1
}
echo "    $(grep -E '^port[[:space:]]*:' "$WORK/after.yaml")"

echo "==> [3/4c] The Gremlin plugin started and listens on ${GREMLIN_PORT}..."
assert_plugin_started
assert_listening "$GREMLIN_PORT" "$DEFAULT_PORT"

echo "==> [3/4d] TCP connect to ${RELEASE}:${GREMLIN_PORT} through the Service..."
assert_service_connect "$GREMLIN_PORT"

# ── phase 4: the user's file from a ConfigMap mounted on gremlin-server.yaml ─

echo "==> [4/4] helm upgrade: gremlin-server.yaml with port: ${GREMLIN_UPGRADE_PORT} from a ConfigMap, arcadedb.plugins.gremlin.port=${GREMLIN_UPGRADE_PORT}..."
with_port "$GREMLIN_UPGRADE_PORT" < "$WORK/image.yaml" > "$WORK/gremlin-server.yaml"
kubectl create configmap -n "$NAMESPACE" "$CONFIGMAP" --from-file="$WORK/gremlin-server.yaml" \
  --dry-run=client -o yaml | kubectl apply -f - >/dev/null
# volumeMounts and volumes are lists, which --set cannot extend: give them whole,
# the release's current entries plus the ConfigMap.
helm get values "$RELEASE" -n "$NAMESPACE" --all -o json > "$WORK/values.json"
jq --arg cm "$CONFIGMAP" --arg path "$YAML" '{
    volumeMounts: ((.volumeMounts // []) + [{name: "gremlin-server-yaml", mountPath: $path, subPath: "gremlin-server.yaml", readOnly: true}]),
    volumes: ((.volumes // []) + [{name: "gremlin-server-yaml", configMap: {name: $cm}}])
  }' "$WORK/values.json" > "$WORK/mount.json"
OLD_UID=$(kubectl get pod -n "$NAMESPACE" "$POD" -o jsonpath='{.metadata.uid}')
helm upgrade "$RELEASE" "$CHART_DIR" -n "$NAMESPACE" --reuse-values \
  -f "$WORK/mount.json" \
  --set arcadedb.plugins.gremlin.port="$GREMLIN_UPGRADE_PORT" \
  --timeout "${ROLLOUT_TIMEOUT}s" --wait >/dev/null
wait_replaced "$OLD_UID"

assert_seed_kept 4/4a

echo "==> [4/4b] The server reads the ConfigMap's gremlin-server.yaml..."
PORT_LINES=$(port_lines)
[[ "$PORT_LINES" == "port: ${GREMLIN_UPGRADE_PORT}" ]] || {
  echo "ERROR: expected the single line 'port: ${GREMLIN_UPGRADE_PORT}' in ${YAML}, got: '${PORT_LINES:-<none>}'"
  dump_pod; exit 1
}
echo "    ${PORT_LINES}"

echo "==> [4/4c] The Gremlin plugin started and listens on ${GREMLIN_UPGRADE_PORT}..."
assert_plugin_started
assert_listening "$GREMLIN_UPGRADE_PORT" "$GREMLIN_PORT"

echo "==> [4/4d] TCP connect to ${RELEASE}:${GREMLIN_UPGRADE_PORT} through the Service..."
assert_service_connect "$GREMLIN_UPGRADE_PORT"

echo "==> All externally managed Gremlin port checks passed."
