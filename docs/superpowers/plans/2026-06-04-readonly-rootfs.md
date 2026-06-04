# Read-only Root Filesystem Support — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the ArcadeDB Helm chart run under `securityContext.readOnlyRootFilesystem: true` out of the box by exposing ArcadeDB 26.6.1's `logsDirectory` / `raftStorageDirectory` settings and auto-providing writable volumes for every path the server writes.

**Architecture:** Bump the chart to ArcadeDB 26.6.1. Add `arcadedb.logsDirectory` and `arcadedb.ha.raftStorageDirectory` values, and `readOnlyRootFilesystem: true` to the container security context. In the StatefulSet, make the data and config volume **mounts** unconditional (the volume *source* swaps between a PVC and an `emptyDir` depending on the persistence flags), and always mount `emptyDir` volumes for logs and `/tmp`, plus a raft `emptyDir` when HA is active. Logs are wired via the `ARCADEDB_LOG_DIR` env var; raft storage via a `-D` arg in the existing HA command block.

**Tech Stack:** Helm 3, helm-unittest 0.5.2 (`make test-unit`), Go templating.

---

## File Structure

- `charts/arcadedb/Chart.yaml` — version + appVersion bump.
- `charts/arcadedb/values.yaml` — new values: `arcadedb.logsDirectory`, `arcadedb.ha.raftStorageDirectory`, `securityContext.readOnlyRootFilesystem`.
- `charts/arcadedb/templates/statefulset.yaml` — env var, `-D` arg, volumeMounts restructure, volumes restructure.
- `charts/arcadedb/tests/statefulset_test.yaml` — update 2 stale image assertions, update 2 persistence tests whose semantics change, add new coverage.

The HA-active condition `or (gt (int .Values.replicaCount) 1) .Values.autoscaling.enabled` already appears in `statefulset.yaml`; reuse it verbatim for raft.

---

## Task 1: Bump chart to ArcadeDB 26.6.1 and fix stale image assertions

The suite currently has 2 failing tests asserting the old `26.4.2` tag against a 26.5.1 chart. Bumping to 26.6.1 and updating those assertions gets the suite green as a baseline.

**Files:**
- Modify: `charts/arcadedb/Chart.yaml:8` and `:10`
- Modify: `charts/arcadedb/tests/statefulset_test.yaml:50` and `:67`

- [ ] **Step 1: Bump `Chart.yaml`**

Change line 8 `version: 26.5.1` → `version: 26.6.1` and line 10 `appVersion: "26.5.1"` → `appVersion: "26.6.1"`.

- [ ] **Step 2: Update the two stale image-tag assertions**

In `charts/arcadedb/tests/statefulset_test.yaml`, line 50:
```yaml
          value: arcadedata/arcadedb:26.6.1
```
and line 67:
```yaml
          value: my-registry.example.com/arcadedb-fork:26.6.1
```

- [ ] **Step 3: Run the suite — expect green baseline**

Run: `make test-unit`
Expected: `Tests: 0 failed, 126 passed` (the 2 previously-failing image tests now pass).

- [ ] **Step 4: Commit**

```bash
git add charts/arcadedb/Chart.yaml charts/arcadedb/tests/statefulset_test.yaml
git commit -m "chore(helm): bump chart to ArcadeDB 26.6.1"
```

---

## Task 2: Default the container root filesystem to read-only

`statefulset.yaml` already renders the whole `securityContext` via `{{- with .Values.securityContext }}{{- toYaml . }}`, so adding the key to `values.yaml` is sufficient — no template change.

**Files:**
- Modify: `charts/arcadedb/values.yaml:96-101` (the `securityContext` block)
- Modify: `charts/arcadedb/tests/statefulset_test.yaml` (extend the "container-level security context defaults render" test, ~line 193)

- [ ] **Step 1: Write the failing assertion**

In `charts/arcadedb/tests/statefulset_test.yaml`, inside the `it: container-level security context defaults render` test (after the `capabilities.drop[0]` assert, ~line 206), add:
```yaml
      - equal:
          path: spec.template.spec.containers[0].securityContext.readOnlyRootFilesystem
          value: true
```

- [ ] **Step 2: Run it — expect fail**

Run: `make test-unit`
Expected: FAIL — `readOnlyRootFilesystem` is null / not set.

- [ ] **Step 3: Add the value**

In `charts/arcadedb/values.yaml`, change the `securityContext` block (lines 95-101) to:
```yaml
## @param securityContext Container-level security context
securityContext:
  runAsUser: 1000
  runAsGroup: 1000
  allowPrivilegeEscalation: false
  ## readOnlyRootFilesystem hardens the container; the chart provides writable
  ## emptyDir mounts for logs, /tmp, Raft storage, and (when their PVCs are
  ## disabled) the database and config directories.
  readOnlyRootFilesystem: true
  capabilities:
    drop: [ALL]
```

- [ ] **Step 4: Run it — expect pass**

Run: `make test-unit`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add charts/arcadedb/values.yaml charts/arcadedb/tests/statefulset_test.yaml
git commit -m "feat(helm): default container to readOnlyRootFilesystem"
```

---

## Task 3: Writable log, /tmp, and data/config mounts

Under a read-only root, the server's log dir and `/tmp` need writable mounts, and the data/config **mounts** must always be present (swapping their source between a PVC and an `emptyDir`). This task also wires the `ARCADEDB_LOG_DIR` env var.

**Files:**
- Modify: `charts/arcadedb/values.yaml` (add `arcadedb.logsDirectory`, ~after line 17)
- Modify: `charts/arcadedb/templates/statefulset.yaml` (env ~line 115, volumeMounts lines 82-93, volumes lines 119-122)
- Modify: `charts/arcadedb/tests/statefulset_test.yaml` (rewrite 2 tests, add new ones)

- [ ] **Step 1: Write the failing tests**

In `charts/arcadedb/tests/statefulset_test.yaml`, **replace** the test at line 234 (`it: persistence disabled removes volumeMount and volumeClaimTemplate`) — its semantics change because the data mount is now always present — with:
```yaml
  - it: persistence disabled drops the data VCT and backs the data dir with an emptyDir
    set:
      persistence.enabled: false
    asserts:
      - isEmpty:
          path: spec.volumeClaimTemplates
      - contains:
          path: spec.template.spec.containers[0].volumeMounts
          content:
            name: arcadedb-data
            mountPath: /home/arcadedb/databases
      - contains:
          path: spec.template.spec.volumes
          content:
            name: arcadedb-data
            emptyDir: {}
```

**Replace** the test at line 466 (`it: config persistence disabled by default — no config volumeMount or VCT`) with:
```yaml
  - it: config persistence disabled by default — config dir is a writable emptyDir, no VCT
    asserts:
      - contains:
          path: spec.template.spec.containers[0].volumeMounts
          content:
            name: arcadedb-config
            mountPath: /home/arcadedb/config
      - contains:
          path: spec.template.spec.volumes
          content:
            name: arcadedb-config
            emptyDir: {}
      - notExists:
          path: spec.volumeClaimTemplates[1]
```

Then **append** these new tests at the end of the file:
```yaml
  - it: log dir is wired via ARCADEDB_LOG_DIR and backed by a writable emptyDir
    asserts:
      - contains:
          path: spec.template.spec.containers[0].env
          content:
            name: ARCADEDB_LOG_DIR
            value: /home/arcadedb/log
      - contains:
          path: spec.template.spec.containers[0].volumeMounts
          content:
            name: arcadedb-logs
            mountPath: /home/arcadedb/log
      - contains:
          path: spec.template.spec.volumes
          content:
            name: arcadedb-logs
            emptyDir: {}

  - it: a writable emptyDir is mounted at /tmp for the JVM
    asserts:
      - contains:
          path: spec.template.spec.containers[0].volumeMounts
          content:
            name: arcadedb-tmp
            mountPath: /tmp
      - contains:
          path: spec.template.spec.volumes
          content:
            name: arcadedb-tmp
            emptyDir: {}

  - it: arcadedb.logsDirectory override flows through to env and mount
    set:
      arcadedb.logsDirectory: /var/log/arcadedb
    asserts:
      - contains:
          path: spec.template.spec.containers[0].env
          content:
            name: ARCADEDB_LOG_DIR
            value: /var/log/arcadedb
      - contains:
          path: spec.template.spec.containers[0].volumeMounts
          content:
            name: arcadedb-logs
            mountPath: /var/log/arcadedb

  - it: config persistence enabled uses the PVC, not an emptyDir
    set:
      persistence.config.enabled: true
    asserts:
      - notContains:
          path: spec.template.spec.volumes
          content:
            name: arcadedb-config
            emptyDir: {}
```

- [ ] **Step 2: Run the suite — expect failures**

Run: `make test-unit`
Expected: FAIL — `ARCADEDB_LOG_DIR` env missing, `arcadedb-logs` / `arcadedb-tmp` volumes missing, data/config emptyDir sources missing.

- [ ] **Step 3: Add the `logsDirectory` value**

In `charts/arcadedb/values.yaml`, after the `extraEnvironment` param (line 17), inside the `arcadedb:` block, add:
```yaml
  ## @param arcadedb.logsDirectory Directory where the server writes log files.
  ## Backed by a writable emptyDir and forwarded via the ARCADEDB_LOG_DIR env var
  ## so logging works under readOnlyRootFilesystem.
  logsDirectory: "/home/arcadedb/log"
```

- [ ] **Step 4: Add the `ARCADEDB_LOG_DIR` env var**

In `charts/arcadedb/templates/statefulset.yaml`, the `rootPassword` env entry ends at line 115 (`{{- end }}`), immediately before `{{- with .Values.arcadedb.extraEnvironment }}`. Insert between them:
```yaml
            - name: ARCADEDB_LOG_DIR
              value: {{ .Values.arcadedb.logsDirectory | quote }}
```

- [ ] **Step 5: Make the data/config mounts unconditional and add logs + tmp mounts**

In `charts/arcadedb/templates/statefulset.yaml`, replace the `volumeMounts:` block (lines 82-93):
```yaml
          volumeMounts:
            {{- if .Values.persistence.enabled }}
            - name: arcadedb-data
              mountPath: {{ .Values.arcadedb.databaseDirectory }}
            {{- end }}
            {{- if .Values.persistence.config.enabled }}
            - name: arcadedb-config
              mountPath: {{ .Values.arcadedb.configDirectory }}
            {{- end }}
            {{- with .Values.volumeMounts }}
            {{- toYaml . | nindent 12 }}
            {{- end }}
```
with:
```yaml
          volumeMounts:
            - name: arcadedb-data
              mountPath: {{ .Values.arcadedb.databaseDirectory }}
            - name: arcadedb-config
              mountPath: {{ .Values.arcadedb.configDirectory }}
            - name: arcadedb-logs
              mountPath: {{ .Values.arcadedb.logsDirectory }}
            - name: arcadedb-tmp
              mountPath: /tmp
            {{- with .Values.volumeMounts }}
            {{- toYaml . | nindent 12 }}
            {{- end }}
```

- [ ] **Step 6: Add the volume sources (emptyDir fallbacks + logs + tmp)**

In `charts/arcadedb/templates/statefulset.yaml`, replace the conditional volumes block (lines 119-122):
```yaml
      {{- with .Values.volumes }}
      volumes:
        {{- toYaml . | nindent 8 }}
      {{- end }}
```
with an unconditional block:
```yaml
      volumes:
        - name: arcadedb-logs
          emptyDir: {}
        - name: arcadedb-tmp
          emptyDir: {}
        {{- if not .Values.persistence.enabled }}
        - name: arcadedb-data
          emptyDir: {}
        {{- end }}
        {{- if not .Values.persistence.config.enabled }}
        - name: arcadedb-config
          emptyDir: {}
        {{- end }}
        {{- with .Values.volumes }}
        {{- toYaml . | nindent 8 }}
        {{- end }}
```

Note: `arcadedb-data` / `arcadedb-config` are provided by `volumeClaimTemplates` when their persistence flag is enabled and by the `emptyDir` here when disabled — exactly one source each, so no name collision.

- [ ] **Step 7: Run the suite — expect pass**

Run: `make test-unit`
Expected: PASS — all suites green.

- [ ] **Step 8: Commit**

```bash
git add charts/arcadedb/values.yaml charts/arcadedb/templates/statefulset.yaml charts/arcadedb/tests/statefulset_test.yaml
git commit -m "feat(helm): writable log, tmp, and data/config mounts for readOnlyRootFilesystem"
```

---

## Task 4: Relocate Raft storage to a writable mount (HA only)

When HA is active, ArcadeDB writes `raft-storage-<node>` folders under the server root. Relocate them to a configurable, writable `emptyDir`, gated on the existing HA condition.

**Files:**
- Modify: `charts/arcadedb/values.yaml` (add `arcadedb.ha.raftStorageDirectory`)
- Modify: `charts/arcadedb/templates/statefulset.yaml` (HA command block ~line 64, volumeMounts, volumes)
- Modify: `charts/arcadedb/tests/statefulset_test.yaml` (add HA-on / HA-off tests)

- [ ] **Step 1: Write the failing tests**

Append to `charts/arcadedb/tests/statefulset_test.yaml`:
```yaml
  - it: HA active wires raftStorageDirectory arg and a writable raft emptyDir
    set:
      replicaCount: 3
    asserts:
      - contains:
          path: spec.template.spec.containers[0].command
          content: -Darcadedb.ha.raftStorageDirectory=/home/arcadedb/raft
      - contains:
          path: spec.template.spec.containers[0].volumeMounts
          content:
            name: arcadedb-raft
            mountPath: /home/arcadedb/raft
      - contains:
          path: spec.template.spec.volumes
          content:
            name: arcadedb-raft
            emptyDir: {}

  - it: single-node has no raft storage wiring
    asserts:
      - notContains:
          path: spec.template.spec.containers[0].command
          content: -Darcadedb.ha.raftStorageDirectory=/home/arcadedb/raft
      - notContains:
          path: spec.template.spec.volumes
          content:
            name: arcadedb-raft
            emptyDir: {}

  - it: raftStorageDirectory override flows through when HA active
    set:
      replicaCount: 3
      arcadedb.ha.raftStorageDirectory: /data/raft
    asserts:
      - contains:
          path: spec.template.spec.containers[0].command
          content: -Darcadedb.ha.raftStorageDirectory=/data/raft
      - contains:
          path: spec.template.spec.containers[0].volumeMounts
          content:
            name: arcadedb-raft
            mountPath: /data/raft
```

- [ ] **Step 2: Run the suite — expect failures**

Run: `make test-unit`
Expected: FAIL — raft arg / mount / volume absent.

- [ ] **Step 3: Add the `raftStorageDirectory` value**

In `charts/arcadedb/values.yaml`, the `arcadedb:` block has no `ha:` key yet. Add one (place it after the `logsDirectory` param added in Task 3):
```yaml
  ## @section arcadedb.ha
  ha:
    ## @param arcadedb.ha.raftStorageDirectory Parent directory for the per-node
    ## raft-storage-<node> folders. Backed by a writable emptyDir; only used when
    ## HA is active (replicaCount > 1 or autoscaling enabled).
    raftStorageDirectory: "/home/arcadedb/raft"
```

- [ ] **Step 4: Add the `-D` arg in the HA command block**

In `charts/arcadedb/templates/statefulset.yaml`, the HA block sets `raftPort` at line 64. Immediately after that line (still inside the `{{- if or ... }}` block ending line 65), add:
```yaml
            - -Darcadedb.ha.raftStorageDirectory={{ .Values.arcadedb.ha.raftStorageDirectory }}
```

- [ ] **Step 5: Add the raft mount (HA only)**

In `charts/arcadedb/templates/statefulset.yaml` `volumeMounts:` block (from Task 3), after the `arcadedb-tmp` mount and before `{{- with .Values.volumeMounts }}`, add:
```yaml
            {{- if or (gt (int .Values.replicaCount) 1) .Values.autoscaling.enabled }}
            - name: arcadedb-raft
              mountPath: {{ .Values.arcadedb.ha.raftStorageDirectory }}
            {{- end }}
```

- [ ] **Step 6: Add the raft volume source (HA only)**

In `charts/arcadedb/templates/statefulset.yaml` `volumes:` block (from Task 3), after the `arcadedb-tmp` volume, add:
```yaml
        {{- if or (gt (int .Values.replicaCount) 1) .Values.autoscaling.enabled }}
        - name: arcadedb-raft
          emptyDir: {}
        {{- end }}
```

- [ ] **Step 7: Run the suite — expect pass**

Run: `make test-unit`
Expected: PASS — all suites green.

- [ ] **Step 8: Commit**

```bash
git add charts/arcadedb/values.yaml charts/arcadedb/templates/statefulset.yaml charts/arcadedb/tests/statefulset_test.yaml
git commit -m "feat(helm): relocate Raft storage to a writable mount under readOnlyRootFilesystem"
```

---

## Task 5: Lint and full verification

- [ ] **Step 1: helm lint**

Run: `make lint`
Expected: `1 chart(s) linted, 0 chart(s) failed`.

- [ ] **Step 2: Render and eyeball the default + HA output**

Run: `helm template t charts/arcadedb | grep -nE "readOnlyRootFilesystem|ARCADEDB_LOG_DIR|emptyDir|arcadedb-(logs|tmp|data|config)"`
Expected (default, single node): `readOnlyRootFilesystem: true`, the `ARCADEDB_LOG_DIR` env, and `arcadedb-logs` / `arcadedb-tmp` / `arcadedb-config` emptyDir volumes; `arcadedb-data` is a PVC (no data emptyDir).

Run: `helm template t charts/arcadedb --set replicaCount=3 | grep -nE "raftStorageDirectory|arcadedb-raft"`
Expected: the `-Darcadedb.ha.raftStorageDirectory=...` arg plus the `arcadedb-raft` mount and emptyDir volume.

- [ ] **Step 3: Full unit suite**

Run: `make test-unit`
Expected: `Test Suites: 0 failed`, all tests passing.

---

## Notes / deferred

- **Integration test (kind HA suite):** no plan changes. Bumping to 26.6.1 with `readOnlyRootFilesystem: true` means the existing 3-pod HA integration suite (`ci/integration-test.sh`) now exercises the read-only path; a missing writable mount would surface as a rollout/Raft-convergence failure. Requires the `arcadedata/arcadedb:26.6.1` image to be published. Run `make test-integration` once that image is available; do not block the unit-test PR on it.
- **`/tmp` necessity** is unverified against the 26.6.1 image; included as standard hardening insurance (harmless if unused).
