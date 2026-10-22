#!/usr/bin/env bash
# Guard for failedTemplate assertions (#59).
#
# helm-unittest 0.5.2 (pinned in the Makefile) knows only `errorMessage` on
# failedTemplate. Any other key, `errorPattern` included, is dropped when the YAML
# is decoded, and a failedTemplate with no errorMessage passes on ANY render
# failure. Seventeen errorPattern assertions only proved that the render failed,
# and one of them was passing on a different guard's message.
#
# 1. Static check: every failedTemplate assertion under tests/*_test.yaml must
#    carry an errorMessage (exact match), and errorPattern must not appear.
# 2. Negative control: tests/negative-control/*.yaml holds assertions that must
#    all FAIL. If one passes, the installed plugin no longer checks errorMessage
#    and the static check above guards nothing.
#
# Upgrading helm-unittest to a release that matches errorPattern is the time to
# relax check 1, after adding an errorPattern case to the negative control.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CHART_DIR="$ROOT/charts/arcadedb"
HELM="${HELM:-helm}"
status=0

# --- 1. static check -------------------------------------------------------
# A failedTemplate line is either inline (`failedTemplate: { errorMessage: ... }`)
# or a block whose next significant line is `errorMessage:`, indented deeper.
static_errors=$(awk '
  function indent(s) { match(s, /^[ \t-]*/); return RLENGTH }
  function report(f, l) { printf "%s:%d: failedTemplate without errorMessage passes on any render failure\n", f, l }
  FNR == 1 && pending { report(pending_file, pending_line); pending = 0 }
  /errorPattern[[:space:]]*:/ {
    printf "%s:%d: errorPattern is not checked by helm-unittest 0.5.2; use errorMessage\n", FILENAME, FNR
  }
  pending && /^[[:space:]]*(#.*)?$/ { next }
  pending {
    if (!($0 ~ /^[[:space:]]*errorMessage[[:space:]]*:/ && indent($0) > pending_indent))
      report(pending_file, pending_line)
    pending = 0
  }
  /^[[:space:]]*-?[[:space:]]*failedTemplate[[:space:]]*:/ {
    rest = $0; sub(/^[^:]*:[[:space:]]*/, "", rest); sub(/[[:space:]]*#.*$/, "", rest)
    if (rest == "") { pending = 1; pending_file = FILENAME; pending_line = FNR; pending_indent = indent($0) }
    else if (rest !~ /errorMessage[[:space:]]*:/) report(FILENAME, FNR)
  }
  END { if (pending) report(pending_file, pending_line) }
' "$CHART_DIR"/tests/*_test.yaml)

if [ -n "$static_errors" ]; then
  echo "failedTemplate static check FAILED:"
  echo "$static_errors"
  status=1
else
  echo "failedTemplate static check: OK"
fi

# --- 2. negative control ---------------------------------------------------
control_files=("$CHART_DIR"/tests/negative-control/*.yaml)
expected=$(cat "${control_files[@]}" | grep -cE '^[[:space:]]*-[[:space:]]+it:')
output=$("$HELM" unittest "$CHART_DIR" -f 'tests/negative-control/*.yaml' 2>&1 || true)
summary=$(printf '%s\n' "$output" | grep -E '^Tests:' || true)

if printf '%s\n' "$summary" | grep -qE "^Tests:[[:space:]]+${expected} failed, 0 passed, ${expected} total"; then
  echo "failedTemplate negative control: OK (${expected} of ${expected} control assertions failed as expected)"
else
  echo "failedTemplate negative control FAILED: expected all ${expected} control assertions to fail."
  echo "The installed helm-unittest does not compare errorMessage with the render error,"
  echo "so failedTemplate assertions in tests/ would pass on any failure."
  printf '%s\n' "$output"
  status=1
fi

exit "$status"
