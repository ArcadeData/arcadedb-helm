# Issue #16 — plugins badly rendered if config.class is not set

## Problem

When a custom plugin is enabled without a `class`, the `arcadedb.plugin.parameters`
helper renders a broken flag:

```
-Darcadedb.server.plugins=bolt:%!s()
```

The `%!s()` is Go's formatting error for a missing/nil value passed to `printf "%s:%s"`.
The rendered StatefulSet command is silently wrong; the server would fail to load the
plugin at runtime with no obvious cause.

## Root cause

`charts/arcadedb/templates/_helpers.tpl`, custom-plugin branch of
`arcadedb.plugin.parameters`:

```
{{- else -}}
{{- $plugins = append $plugins (printf "%s:%s" $plugin $config.class) -}}
{{- end -}}
```

`$config.class` is empty/nil when the user omits it. The sibling helper
`_arcadedb.plugin.ports` already fails fast for a missing `port` on custom plugins,
but there is no equivalent guard for `class`.

## Fix

Add a fail-fast validation for a missing `class` on custom plugins, mirroring the
existing missing-`port` guard in `_arcadedb.plugin.ports`.

## Expected vs actual

- **Actual:** silent render of `<name>:%!s()`.
- **Expected:** template render fails with a clear message telling the user which
  custom plugin is missing its `class`.

## Tests

Added to `charts/arcadedb/tests/helpers_test.yaml`:
- custom plugin enabled without `class` → `failedTemplate`.
- (regression) custom plugin with `class` still renders correctly (already covered).

Result: `helm unittest charts/arcadedb` → 165/165 pass; `helm lint` clean.

## Pull request

https://github.com/ArcadeData/arcadedb-helm/pull/17

## Review cycles

- **cycle 1** — head `30ae750`
  - changes: fail-fast guard for missing custom-plugin `class` + unit test + tracking doc.
  - `gemini-code-assist`: COMMENTED — "There are no review comments to address, and no
    further feedback is provided." No actionable items.
  - `claude`: no response within the 15-minute poll window (bot appears inactive on this
    repo — no `claude`-authored reviews on the last 20 PRs).

## Final state

`timeout` — only one of the two configured reviewers (`gemini-code-assist`) responded, and
its review carried no actionable items. No code changes were required by review. PR left
open for the developer to merge.
