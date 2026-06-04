# Read-only root filesystem support

**Date:** 2026-06-04
**Branch:** `add-log-dir`
**Status:** Approved (pending spec review)

## Motivation

ArcadeDB 26.6.1 adds two settings (introduced upstream in
[arcadedb-docs@0200db0](https://github.com/ArcadeData/arcadedb-docs/commit/0200db09640c6495d026b6f1b7a877831e4daa2a))
that exist specifically to let the server run under Kubernetes
`securityContext.readOnlyRootFilesystem: true`:

- `arcadedb.server.logsDirectory` (default `./log`) — directory the server
  writes log files to. Resolved very early at startup from, in order: system
  property, environment variable (`ARCADEDB_LOG_DIR`, forwarded by the server
  scripts), then this setting. Supports `${...}` placeholders.
- `arcadedb.ha.raftStorageDirectory` (default empty = server root path) —
  parent directory under which per-node `raft-storage-<nodeName>` folders are
  created.

This chart currently runs without `readOnlyRootFilesystem`, so ArcadeDB writes
logs and Raft storage into the container's ephemeral writable layer. The goal:
ship a hardened-by-default chart where the root filesystem is read-only and the
server still works in every mode (single-node and HA, persistent and dev).

## Goals

- Expose the two new settings as chart values.
- Make `readOnlyRootFilesystem: true` the default container security posture.
- Automatically provide a writable volume for **every** path ArcadeDB writes,
  so the chart works out of the box without the user wiring volumes manually.
- Bump the chart to ArcadeDB 26.6.1 (the first image that supports the settings).

## Non-goals

- Persisting logs or Raft storage durably. They are ephemeral today (container
  writable layer); relocating them to `emptyDir` preserves that semantic. Raft
  state re-syncs via `KubernetesAutoJoin` on pod restart.
- A separate `hardening:`/`securityHardening:` config block. We reuse the
  existing `securityContext` and `persistence` surfaces.

## Design

### New values (`values.yaml`)

```yaml
arcadedb:
  ## @param arcadedb.logsDirectory Directory where the server writes log files.
  ## Mounted as a writable emptyDir so it works under readOnlyRootFilesystem.
  ## Forwarded to the server via the ARCADEDB_LOG_DIR environment variable.
  logsDirectory: "/home/arcadedb/log"
  ha:
    ## @param arcadedb.ha.raftStorageDirectory Parent directory for the per-node
    ## raft-storage-<node> folders. Mounted as a writable emptyDir under
    ## readOnlyRootFilesystem. Only used when HA is active (replicaCount > 1 or
    ## autoscaling enabled).
    raftStorageDirectory: "/home/arcadedb/raft"
```

`securityContext` (container-level) gains:

```yaml
securityContext:
  runAsUser: 1000
  runAsGroup: 1000
  allowPrivilegeEscalation: false
  readOnlyRootFilesystem: true   # NEW
  capabilities:
    drop: [ALL]
```

### Writable mounts (StatefulSet)

With a read-only root, every path ArcadeDB writes must be a mounted volume. The
chart supplies them automatically:

| Path                         | Volume                       | Condition                                   |
|------------------------------|------------------------------|---------------------------------------------|
| `databaseDirectory`          | PVC `arcadedb-data`          | `persistence.enabled` (default) — unchanged |
| `databaseDirectory`          | emptyDir `arcadedb-data`     | `persistence.enabled = false` — new fallback |
| `configDirectory`            | PVC `arcadedb-config`        | `persistence.config.enabled` — unchanged    |
| `configDirectory`            | emptyDir `arcadedb-config`   | `persistence.config.enabled = false` (default) — new fallback |
| `arcadedb.logsDirectory`     | emptyDir `arcadedb-logs`     | always                                      |
| `arcadedb.ha.raftStorageDirectory` | emptyDir `arcadedb-raft` | HA active only                              |
| `/tmp`                       | emptyDir `arcadedb-tmp`      | always (JVM `java.io.tmpdir`)               |

The data/config emptyDir fallbacks replace the previous implicit write to the
container's root layer; they have identical (ephemeral, pod-lifetime) durability,
so behavior is unchanged for those modes — they just make read-only root work.

`emptyDir` volume names reuse the existing `arcadedb-data` / `arcadedb-config`
mount names so the `volumeMounts` block stays a single definition; only the
volume *source* (PVC via `volumeClaimTemplates` vs `emptyDir` in `volumes`)
differs by condition.

### Wiring

- **Logs:** set the `ARCADEDB_LOG_DIR` environment variable to
  `arcadedb.logsDirectory`. This is the documented, resolved-very-early
  mechanism the server scripts forward — more robust than a `-D` arg for logging
  init. Added to the existing `env:` list.
- **Raft storage:** append `-Darcadedb.ha.raftStorageDirectory={{ .Values.arcadedb.ha.raftStorageDirectory }}`
  inside the existing `{{- if or (gt replicaCount 1) autoscaling.enabled }}` HA
  block in `command:`.

### Version

- `Chart.yaml`: `version` and `appVersion` → `26.6.1`.

## Testing

### Unit (helm-unittest)

- `ARCADEDB_LOG_DIR` env present with the configured value.
- `/tmp`, logs emptyDir volumes + mounts present by default.
- `readOnlyRootFilesystem: true` on the container securityContext.
- HA on: `-Darcadedb.ha.raftStorageDirectory=...` arg present and `arcadedb-raft`
  emptyDir volume + mount present.
- HA off (default single node): no raft arg, no `arcadedb-raft` volume.
- `persistence.config.enabled = false` (default): `arcadedb-config` is an
  emptyDir, not a PVC; mount still present at `configDirectory`.
- `persistence.enabled = false`: `arcadedb-data` is an emptyDir.
- Update the two stale `statefulset_test.yaml` image assertions
  `26.4.2` → `26.6.1` (currently failing against the 26.5.1 chart).

### Integration (kind, existing 3-pod HA suite)

No new phases required. Bumping to 26.6.1 with `readOnlyRootFilesystem: true`
default means the existing HA integration suite now exercises the read-only
root path end to end; a startup failure (missing writable mount) would surface
as a rollout/Raft-convergence failure in the current phases.

## Risks

- **Unverified `/tmp` need.** Included as standard hardening insurance; if 26.6.1
  never writes to `/tmp` it is a harmless empty mount.
- **Image availability.** The `arcadedata/arcadedb:26.6.1` image must be
  published before the integration test passes in CI.
