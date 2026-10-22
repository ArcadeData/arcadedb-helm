#!/usr/bin/env bash
# Drift guard (#42): every -Darcadedb.* setting the chart renders must still be a
# setting of the server image it targets. The server does not warn about an
# unknown -D system property, so after a rename the flag is a silent no-op that a
# smoke test booting the pod does not catch. The same holds for the settings the
# chart passes as environment variables named after their key (arcadedb.ssl.*
# store passwords, #41; the pre-26.11.1 HA root password, #45), so those env var
# names are collected too.
#
# Renders the chart with representative values, collects the -Darcadedb.* keys
# and the arcadedb.* env var names,
# and compares them with GlobalConfiguration of the JVM image (listed by
# ci/ListConfigKeys.java, run with the image's own JDK and classpath). The native
# image of the same version carries the same settings but no JVM, so a -native
# tag is checked against its JVM counterpart.
#
# Keys the server is known not to read go in ci/config-keys-allowlist.txt, each
# with the issue tracking it. An allowlisted key the image now knows fails the
# check, so the list does not outlive the fix.
#
# Env: IMAGE_TAG (default: chart appVersion), IMAGE_REPO (default arcadedata/arcadedb).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CHART_DIR="$ROOT/charts/arcadedb"
ALLOWLIST="$ROOT/ci/config-keys-allowlist.txt"
IMAGE_REPO="${IMAGE_REPO:-arcadedata/arcadedb}"
IMAGE_TAG="${IMAGE_TAG:-$(sed -nE 's/^appVersion:[[:space:]]*"?([^"[:space:]]+)"?.*/\1/p' "$CHART_DIR/Chart.yaml")}"
IMAGE_TAG="${IMAGE_TAG%-native}"
IMAGE="$IMAGE_REPO:$IMAGE_TAG"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

render() {
  helm template config-keys "$CHART_DIR" "$@" >>"$WORK/rendered.yaml"
}

# Representative values: every branch of the chart that emits a -Darcadedb.* flag.
FULL=(
  --set replicaCount=3
  --set tls.enabled=true
  --set tls.certManager.enabled=true
  --set tls.certManager.issuerRef.name=ci
  --set arcadedb.plugins.bolt.enabled=true
  --set arcadedb.plugins.postgres.enabled=true
  --set arcadedb.plugins.mongo.enabled=true
  --set arcadedb.plugins.redis.enabled=true
  --set arcadedb.plugins.prometheus.enabled=true
  --set arcadedb.plugins.prometheus.requireAuthentication=false
  --set observability.logging.format=json
  --set observability.logging.includeTrace=true
  --set observability.metrics.otlp.enabled=true
  --set observability.tracing.enabled=true
)
render
render "${FULL[@]}" --set arcadedb.plugins.gremlin.enabled=true
render "${FULL[@]}" --set image.flavor=native
# HA on a pre-26.11.1 image with a user-supplied password Secret and no cluster
# token: the root password is passed as the env var arcadedb.server.rootPassword.
render --set replicaCount=3 --set image.tag=26.10.2 \
  --set arcadedb.credentials.rootPassword.secret.name=ci \
  --set arcadedb.credentials.rootPassword.secret.key=password

{
  grep -oE -- '-Darcadedb\.[A-Za-z0-9._-]+=' "$WORK/rendered.yaml" \
    | sed -e 's/^-D//' -e 's/=$//'
  # Env vars named after a setting: `- name: arcadedb.<key>` (volume and object
  # names use '-', never '.', after the arcadedb prefix).
  grep -oE -- '^[[:space:]]*- name: arcadedb\.[A-Za-z0-9._-]+[[:space:]]*$' "$WORK/rendered.yaml" \
    | sed -E 's/^[[:space:]]*- name: //; s/[[:space:]]*$//' || true
} | sort -u >"$WORK/chart-keys.txt"

echo "Listing the settings of $IMAGE"
docker pull -q "$IMAGE" >/dev/null
docker run --rm \
  -v "$ROOT/ci/ListConfigKeys.java:/tmp/ListConfigKeys.java:ro" \
  --entrypoint java "$IMAGE" -cp '/home/arcadedb/lib/*' /tmp/ListConfigKeys.java \
  | sed -n 's/^KEY //p' | sort -u >"$WORK/server-keys.txt"

if [ ! -s "$WORK/server-keys.txt" ]; then
  echo "ERROR: no settings listed by $IMAGE" >&2
  exit 1
fi

sed -e 's/#.*//' -e 's/[[:space:]]//g' -e '/^$/d' "$ALLOWLIST" | sort -u >"$WORK/allowed.txt"

missing="$(comm -23 "$WORK/chart-keys.txt" "$WORK/server-keys.txt" | comm -23 - "$WORK/allowed.txt")"
stale="$(comm -12 "$WORK/allowed.txt" "$WORK/server-keys.txt")"

echo "Chart renders $(wc -l <"$WORK/chart-keys.txt" | tr -d ' ') arcadedb.* setting keys (-D flags and env var names); $IMAGE knows $(wc -l <"$WORK/server-keys.txt" | tr -d ' ') settings."
status=0
if [ -n "$missing" ]; then
  echo "ERROR: the chart renders settings (-D flags or env var names) that $IMAGE does not know (renamed or removed?):" >&2
  echo "$missing" | sed 's/^/  /' >&2
  status=1
fi
if [ -n "$stale" ]; then
  echo "ERROR: $IMAGE now knows these allowlisted keys; remove them from ci/config-keys-allowlist.txt:" >&2
  echo "$stale" | sed 's/^/  /' >&2
  status=1
fi
[ "$status" -eq 0 ] && echo "OK: every rendered arcadedb.* setting key is a setting of $IMAGE."
exit "$status"
