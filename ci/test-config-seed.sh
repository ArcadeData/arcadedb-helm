#!/usr/bin/env bash
# Runs the config-seed init container script (charts/arcadedb/files/config-seed.sh)
# against sample config directories. The helm-unittest suites only see the
# rendered text; this checks what the script does to the files: copy-if-absent
# seeding (#39) and the gremlin-server.yaml port rewrite (GREMLIN_PORT, #58).
#
# Runs the script with every POSIX shell found among sh, dash and busybox sh.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$ROOT/charts/arcadedb/files/config-seed.sh"
FILES=(server-groups.json gremlin-server.yaml gremlin-server.properties gremlin-server.groovy)

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

SHELLS=()
for s in sh dash; do
  command -v "$s" >/dev/null 2>&1 && SHELLS+=("$s")
done
command -v busybox >/dev/null 2>&1 && SHELLS+=("busybox sh")

FAILURES=0
fail() { echo "FAIL [$SH] $*"; FAILURES=$((FAILURES + 1)); }

IMAGE_YAML='host: 0.0.0.0
graphs:
  graph: config/gremlin-server.properties
scriptEngines:
  gremlin-lang: {}
serializers:
  - className: org.apache.tinkerpop.gremlin.util.ser.GraphBinaryMessageSerializerV1
    config:
      port: 1234'

# new_case <name>: fresh image dir (src) holding the image's files, empty volume (dst).
new_case() {
  CASE="$WORK/$SH_ID/$1"
  SRC="$CASE/src"; DST="$CASE/dst"
  mkdir -p "$SRC" "$DST"
  printf '%s\n' "$IMAGE_YAML" > "$SRC/gremlin-server.yaml"
  printf '{}\n' > "$SRC/server-groups.json"
  printf 'gremlin.graph=x\n' > "$SRC/gremlin-server.properties"
  printf '// groovy\n' > "$SRC/gremlin-server.groovy"
}

# seed [GREMLIN_PORT]: run the script the way the init container does.
seed() {
  if [ $# -gt 0 ]; then
    GREMLIN_PORT="$1" $SH -c "$(cat "$SCRIPT")" config-seed "$SRC" "$DST" "${FILES[@]}" >"$CASE/out.log" 2>&1
  else
    env -u GREMLIN_PORT $SH -c "$(cat "$SCRIPT")" config-seed "$SRC" "$DST" "${FILES[@]}" >"$CASE/out.log" 2>&1
  fi
}

top_ports() { grep -E '^("|'"'"')?port("|'"'"')? *:' "$DST/gremlin-server.yaml" || true; }

for SH in "${SHELLS[@]}"; do
  SH_ID="${SH// /-}"

  # 1. Default (no GREMLIN_PORT): files seeded byte for byte, no port written.
  new_case default
  seed || fail "default: script exited non-zero: $(cat "$CASE/out.log")"
  for f in "${FILES[@]}"; do
    cmp -s "$SRC/$f" "$DST/$f" || fail "default: $f not seeded verbatim"
  done
  [ -z "$(top_ports)" ] || fail "default: a top-level port was written: $(top_ports)"

  # 2. Fresh volume with GREMLIN_PORT: seeded, then port appended; nested port untouched.
  new_case fresh
  seed 9999 || fail "fresh: script exited non-zero: $(cat "$CASE/out.log")"
  [ "$(top_ports)" = "port: 9999" ] || fail "fresh: top-level port is '$(top_ports)'"
  grep -qx '      port: 1234' "$DST/gremlin-server.yaml" || fail "fresh: nested port: 1234 changed"
  [ "$(grep -v '^port: 9999$' "$DST/gremlin-server.yaml")" = "$IMAGE_YAML" ] \
    || fail "fresh: lines other than port: changed"
  grep -q 'config-seed: set port: 9999 in gremlin-server.yaml' "$CASE/out.log" || fail "fresh: no log line"
  ls -A "$DST" | grep -q '^\.' && fail "fresh: temp file left behind: $(ls -A "$DST")"

  # 3. Every start rewrites: a second run with a new port replaces, never duplicates.
  seed 9999
  cp "$DST/gremlin-server.yaml" "$CASE/after-first"
  seed 9999
  cmp -s "$CASE/after-first" "$DST/gremlin-server.yaml" || fail "rerun: same port is not idempotent"
  seed 8183
  [ "$(top_ports)" = "port: 8183" ] || fail "rerun: port not replaced: '$(top_ports)'"

  # 4. Operator-edited file with its own port: replaced in place, rest kept.
  new_case edited
  printf 'host: 0.0.0.0\nport: 8182\n# operator note\nthreadPoolWorker: 4\n' > "$DST/gremlin-server.yaml"
  seed 7777
  [ "$(cat "$DST/gremlin-server.yaml")" = "$(printf 'host: 0.0.0.0\nport: 7777\n# operator note\nthreadPoolWorker: 4')" ] \
    || fail "edited: unexpected result: $(cat "$DST/gremlin-server.yaml")"
  grep -q 'config-seed: keeping existing gremlin-server.yaml' "$CASE/out.log" || fail "edited: file was re-seeded"

  # 5. Without GREMLIN_PORT an operator-edited file is left byte for byte.
  new_case untouched
  printf 'host: 0.0.0.0\nport: 8190\n' > "$DST/gremlin-server.yaml"
  cp "$DST/gremlin-server.yaml" "$CASE/before"
  seed
  cmp -s "$CASE/before" "$DST/gremlin-server.yaml" || fail "untouched: file changed without GREMLIN_PORT"

  # 6. Duplicate, quoted and spaced top-level keys collapse into one port line; no trailing newline kept.
  new_case variants
  printf 'host: 0.0.0.0\n"port": 1\nport : 2\n'"'"'port'"'"': 3\nlast: line' > "$DST/gremlin-server.yaml"
  seed 9000
  [ "$(cat "$DST/gremlin-server.yaml")" = "$(printf 'host: 0.0.0.0\nport: 9000\nlast: line')" ] \
    || fail "variants: unexpected result: $(cat "$DST/gremlin-server.yaml")"

  # 7. No gremlin-server.yaml in the image or on the volume: one holding the port is created.
  new_case absent
  rm "$SRC/gremlin-server.yaml"
  seed 9001
  [ "$(cat "$DST/gremlin-server.yaml")" = "port: 9001" ] \
    || fail "absent: unexpected result: $(cat "$DST/gremlin-server.yaml" 2>&1)"

  # 8. A key that only starts with "port" is not the port.
  new_case prefix
  printf 'portable: yes\nports: [1]\n' > "$DST/gremlin-server.yaml"
  seed 9002
  [ "$(cat "$DST/gremlin-server.yaml")" = "$(printf 'portable: yes\nports: [1]\nport: 9002')" ] \
    || fail "prefix: unexpected result: $(cat "$DST/gremlin-server.yaml")"

  echo "config-seed script checked with: $SH"
done

if [ "$FAILURES" -ne 0 ]; then
  echo "$FAILURES config-seed check(s) failed"
  exit 1
fi
echo "All config-seed checks passed (${#SHELLS[@]} shell(s))."
