# Issue #22 — Console doesn't work: read-only file system

**Issue:** https://github.com/ArcadeData/arcadedb-helm/issues/22
**Branch:** `fix/22-console-read-only-filesystem`
**Type:** bug

## Reported behaviour

Shelling into a pod and running `bin/console.sh` prints a stack trace after every
command:

```
WARNING: Failed to save history
java.nio.file.FileSystemException: /home/arcadedb/.history: Read-only file system
        ...
        at org.jline.reader.impl.history.DefaultHistory.save(DefaultHistory.java:389)
        at com.arcadedb.console.Console.interactiveMode(Console.java:142)
```

## Root cause

`Console.interactiveMode()` builds its JLine reader with a **relative** history
file name:

```java
LineReaderBuilder.builder()...variable("history-file", ".history")
```

JLine resolves it with `Path.of(".history").toAbsolutePath()`, i.e. against the
JVM working directory (`user.dir`). The image's `WORKDIR` is `/home/arcadedb`, so
the history file lands at `/home/arcadedb/.history` — inside the image install
directory, which is unwritable because the chart defaults to
`securityContext.readOnlyRootFilesystem: true` (added in the read-only-root
hardening work, see `docs/superpowers/specs/2026-06-04-readonly-rootfs-design.md`).

Every writable path the chart provides (`/home/arcadedb/databases`,
`/home/arcadedb/config`, `/home/arcadedb/log`, `/home/arcadedb/raft`, `/tmp`) is a
mounted volume; `/home/arcadedb` itself is not, and cannot be — it holds
`bin/`, `lib/` and the rest of the distribution.

### Reproduction (Docker, no cluster needed)

`--read-only` reproduces the pod's `readOnlyRootFilesystem: true`:

```
docker run --rm -it --read-only --tmpfs /tmp:exec,mode=1777 \
  arcadedata/arcadedb:26.8.1 bin/console.sh
```

Typing any command reproduces the reported stack trace byte for byte.

## Why the fix suggested in the issue does not work

The issue proposes mounting an `emptyDir` at `/home/arcadedb/.history`. Kubernetes
creates a **directory** at a mount path — it cannot mount an `emptyDir` (or a
`subPath` of one) as a *file*. JLine then takes a different branch of
`DefaultHistory.internalWrite()`:

```java
createWithOwnerOnlyPermissions(path);            // Files.exists(dir) == true -> no-op
Files.newBufferedWriter(path, WRITE, APPEND);    // throws on a directory
```

Verified against the real image with a probe that mimics `internalWrite()`:

```
$ docker run --rm --read-only --tmpfs /home/arcadedb/.history ... java Probe.java
drwxrwxrwx 2 root root 40 /home/arcadedb/.history
HISTORY_WRITE_FAILED: java.nio.file.FileSystemException: /home/arcadedb/.history: Is a directory
```

So the mount only swaps `Read-only file system` for `Is a directory`.

## Fix

Relocate the **JVM working directory used by interactive tools** to a writable
path, and pin the server process back to the install directory so nothing about
its own behaviour changes.

Both `bin/server.sh` and `bin/console.sh` splice `$ARCADEDB_SETTINGS` into their
`java` command line, and `server.sh` places the chart's `command:` arguments
*after* it — so a later `-Duser.dir` wins for the server only:

| Process | `user.dir` | Source |
|---------|-----------|--------|
| `bin/console.sh` (interactive, `kubectl exec`) | `arcadedb.consoleWorkingDirectory` (`/tmp`) | `ARCADEDB_SETTINGS` env |
| `bin/server.sh` (the pod's main process) | `arcadedb.installDirectory` (`/home/arcadedb`) | `-Duser.dir` in `command:`, overriding the env |

`/tmp` is already backed by the `arcadedb-tmp` `emptyDir`, so no new volume is
needed, and JLine creates the history file with `0600` permissions.

### Why the server must be pinned

Without the pin, `user.dir=/tmp` also applies to the server, and
`ServerPathUtils.setRootPath()` auto-detects `arcadedb.server.rootPath` by probing
`./config` relative to `user.dir`. Verified: the server then resolves
`rootPath` to `/tmp`, fails to write `server-users.jsonl`, and shuts down:

```
Caused by: java.nio.file.NoSuchFileException
  at com.arcadedb.server.security.SecurityUserFileRepository.save(...)
  at com.arcadedb.server.security.ServerSecurity.saveUsers(...)
Received shutdown signal. The server will be halted
```

With the pin, a read-only-root server run is byte-for-byte equivalent to the
current behaviour: `/api/v1/ready` → `204`, `config/` written to
`/home/arcadedb/config`, `defaultDatabases` created under
`/home/arcadedb/databases`.

### Rejected alternatives

- **`workingDir: /tmp` on the container.** Works, but `kubectl exec` sessions then
  start in `/tmp`, so the documented `bin/console.sh` (and the chart's relative
  `command: bin/server.sh`) break. Same blast radius as `-Duser.dir` with worse
  ergonomics.
- **`-Darcadedb.server.rootPath=/home/arcadedb` instead of pinning `user.dir`.**
  Also works, but leaves the server with `user.dir=/tmp`, so any *other*
  cwd-relative path in the server or a plugin silently moves. Pinning `user.dir`
  keeps the server byte-identical to today.
- **Dropping `readOnlyRootFilesystem`.** Undoes deliberate hardening.

## Changes

- `charts/arcadedb/values.yaml`: new `arcadedb.consoleWorkingDirectory` (default
  `/tmp`, `""` disables) and `arcadedb.installDirectory` (default
  `/home/arcadedb`).
- `charts/arcadedb/templates/statefulset.yaml`: render the `ARCADEDB_SETTINGS`
  env var and the `-Duser.dir` server pin.
- `charts/arcadedb/tests/console_history_test.yaml`: new helm-unittest suite.
- `ci/integration-test.sh`: new phase 8 asserting the contract in a live pod.
- `charts/arcadedb/README.md`: document the two new values.

## Test results

### helm-unittest

New suite `console_history_test.yaml` (8 cases): env wiring, writable backing
volume, server pin, both value overrides, the `""` opt-out, `extraEnvironment`
precedence, and HA. All five fix-dependent cases failed before the template
change and pass after.

```
$ make lint && make test-unit
1 chart(s) linted, 0 chart(s) failed
Test Suites: 14 passed, 14 total
Tests:       164 passed, 164 total
```

### kind integration (3-pod HA, `arcadedata/arcadedb:26.8.1`)

```
==> [1/8] ... All 3 pods Ready.
==> [7/8] Transferring Raft leadership...  New leader: test-arcadedb-2...
==> [8/8] Asserting the console can write its history file...
    Console working directory: /tmp
    /tmp/.history is writable.
    Image install directory is read-only, as expected.
    Server process pinned to /home/arcadedb.
    bin/console.sh runs inside the pod.
==> All checks passed.
```

### Interactive console on a live pod

A/B on the same pod, driving `kubectl exec -it ... -- bin/console.sh` through a
pty and typing `help`, `list databases`, `exit`:

| Run | Result |
|-----|--------|
| As deployed by the chart | no warning; `/tmp/.history` written `-rw-------` with all three commands |
| `env -u ARCADEDB_SETTINGS bin/console.sh` (pre-fix behaviour) | the reported `Failed to save history` stack trace |

## Impact

- Interactive console works cleanly under the chart's default hardened posture.
- Server behaviour is unchanged: same working directory, same `rootPath`
  auto-detection, same `config/` and `databases/` locations. Verified against
  `arcadedata/arcadedb:26.8.1` under `--read-only` (`/api/v1/ready` → 204,
  `/api/v1/health` → 204, `defaultDatabases` created, `server-users.jsonl`
  written to `/home/arcadedb/config`).
- History is ephemeral (pod-lifetime), like the `emptyDir` the issue proposed.
- No new volume, no image change, no chart version bump required.

## Follow-ups (not in this change)

- `bin/server.sh` writes its pid file to `$ARCADEDB_HOME/bin/arcadedb.pid`, which
  fails on the read-only root filesystem and logs
  `can't create /home/arcadedb/bin/arcadedb.pid: Read-only file system` at every
  startup. It is cosmetic — the script continues to `exec` the JVM — and the
  script honours a preset `ARCADEDB_PID`, so exporting
  `ARCADEDB_PID=/tmp/arcadedb.pid` would silence it. Out of scope for #22.
- Upstream, `Console.java` hardcodes the relative `.history` and lets a failed
  save print a full stack trace. Making the location configurable (or degrading
  quietly) would fix this for every deployment, not just this chart.
