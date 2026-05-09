# HA Cluster Integration Tests — Design

**Date:** 2026-05-09
**Status:** Draft
**Source:** Support email Q&A on Raft HA behavior (leader control, scale-up sync, large-import tuning)

## Context

The chart already runs a kind-based integration test (`ci/integration-test.sh`) that
brings up a 3-pod HA cluster, verifies Raft consensus, writes via the leader, and
reads back. This design extends that test with scenarios derived from a recent
support exchange about ArcadeDB HA cluster operations.

Three areas were discussed in the support email:

- **Q1** — Controlling the leader: `arcadedb.ha.serverRole=replica` to exclude a
  pod from leadership; runtime leadership transfer via
  `POST /api/v1/cluster/leader`.
- **Q2** — Sync after scale-up: peer-add path (`POST /api/v1/cluster/peer`) and
  the snapshot-install path (`/api/v1/ha/snapshot/{database}`).
- **Q3** — Large (>1 GB) import recipe with replication: bring cluster up before
  importing, drive imports through the leader, tune Raft thresholds.

A new `STATUS` column (HEALTHY / CATCHING_UP / FALLING_BEHIND / STALLED) was
added to the cluster status table in commit `203acdaac` and is the canonical
signal for follower health.

## Goals

Add automated coverage for the support scenarios that are testable inside the
existing kind-based CI job, within the 20-minute job timeout.

## Non-Goals (discarded scenarios)

- **Q1a — `serverRole=replica`:** The chart applies the same `-D` flags to every
  pod. Per-ordinal configuration is a chart change, not a test, and is out of
  scope here.
- **Q2a — 1→3 helm upgrade reproducing the "peer not in `HA_SERVER_LIST`" path:**
  The chart re-renders `arcadedb.ha.serverList` on every upgrade, so the new pod
  is always in the configured list. The wire-level peer-add scenario from the
  support email does not reproduce through Helm.
- **Q3 — Large-import recipe:** Operational guidance for >1 GB datasets. Not
  testable at CI scale; volume too high.

## In-Scope Scenarios

| ID | Scenario | Confidence | Approx. cost |
|----|----------|-----------|--------------|
| P5 | STATUS column reports HEALTHY | High | ~5 s |
| P6 | Runtime leadership transfer | High | ~60 s |
| P7 | Scale-up 3→5 via `helm upgrade` | Medium | 3–5 min |
| P8 | Snapshot-install on follower recovery | Lower (flake-prone) | ~2 min |

## Architecture

Single CI job, single kind cluster, single Helm install. Extend
`ci/integration-test.sh` with new phases. Existing phases stay (rollout →
quorum → write → read). New phases append on the same cluster, with one
`helm upgrade` step in the middle. Order chosen so destructive scenarios
(pod delete) run last and cannot mask earlier signals.

Why one cluster instead of one-per-scenario: each kind cluster create costs
~60 s. Sequencing keeps total CI time well under the existing 20-minute job
timeout.

### Install-time changes

In the `Install chart` step of `.github/workflows/lint.yml`, append a low
snapshot threshold to `arcadedb.extraCommands`:

```
--set 'arcadedb.extraCommands[1]=-Darcadedb.ha.snapshotThreshold=50'
```

Index 1 because index 0 holds the existing `-Darcadedb.server.mode=production`.

A low threshold makes the snapshot-install path reachable without writing
100k rows. It does not affect other scenarios — they each generate fewer
than 50 entries.

### Helpers (additions to `ci/integration-test.sh`)

The existing script already has `pf_start`, `pf_stop`, `pf_wait`, `api`. Add:

- `cluster_status <local-port>` — fetches `GET /api/v1/cluster` and returns the
  parsed JSON via stdout. Callers extract `.leaderId`, `.peers[]`, etc.
- `peer_status <local-port> <peer-id>` — extracts a single peer's `.status`
  field from cluster status. Returns empty string if the field is absent.
- `wait_status_healthy <local-port> <peer-id> <timeout-seconds>` — polls
  `peer_status` until it returns `HEALTHY`. Treats `CATCHING_UP` as transient.
  Fails on `STALLED` or `FALLING_BEHIND` only after the timeout.
- `assert_quorum_n <expected-pod-count>` — generalizes the existing
  hardcoded 0/1/2 loop. Iterates ordinals 0..N-1, port-forwards each, reads
  `leaderId` from each, asserts all agree.

## Phase Detail

### P5 — STATUS=HEALTHY assertion

After the existing read assertion (phase 4), the script port-forwards to the
leader and calls `GET /api/v1/cluster`. For each `peers[]` entry, assert
`status` is `HEALTHY` (or absent — see graceful-skip below).

**Graceful skip on missing field:** If `.peers[0].status` is null/missing on
the deployed image (older than `203acdaac`), log a warning and skip the
assertion. Do not fail. This keeps the test compatible with image tags that
predate the STATUS column.

### P6 — Runtime leadership transfer

1. From cluster status, pick a non-leader peer ID.
2. `POST /api/v1/cluster/leader` with body `{"peerId":"<chosen>"}`.
3. Poll `GET /api/v1/cluster` from any pod for up to 30 s; assert `leaderId`
   matches the chosen peer.
4. Re-run the existing write+read sequence (insert a marker row, read it back)
   via the new leader to confirm the cluster is still functional after the
   transfer.

Choosing a specific target peer (rather than sending an empty body) makes the
assertion deterministic; Ratis would otherwise be free to re-elect the same
pod and the test would have to retry.

### P7 — Scale-up 3→5 via `helm upgrade`

1. `helm upgrade test-arcadedb charts/arcadedb/ --set replicaCount=5
   --reuse-values --wait --timeout 5m`.
2. `kubectl rollout status statefulset/test-arcadedb --timeout 5m` to cover
   the rolling restart of the original 3 pods plus scheduling of pods 3 and 4.
3. Run `assert_quorum_n 5`.
4. Run the STATUS=HEALTHY assertion across all 5 peers (with the same
   graceful-skip behavior as P5).

**No data-persistence assertion.** The CI install runs with
`persistence.enabled=false`, so the rolling restart of pods 0–2 wipes existing
data. The assertion here is purely about cluster topology: the chart's
`arcadedb.nodenames` helper must re-render the serverList correctly so that
all 5 pods agree on a single leader and report HEALTHY.

### P8 — Snapshot install on follower recovery

1. From the post-scale-up leader, write 100 small rows in a loop. With
   `snapshotThreshold=50` (set at install time), the leader will have produced
   a Raft snapshot.
2. Pick a non-leader pod (e.g. ordinal 4). `kubectl delete pod test-arcadedb-4`.
3. Wait for the StatefulSet to recreate the pod and for it to reach `Ready`
   (`kubectl wait --for=condition=Ready pod/test-arcadedb-4 --timeout=2m`).
4. Poll cluster status for up to 90 s; assert the recreated peer reaches
   `STATUS=HEALTHY`.
5. **Secondary signal (best-effort):** `kubectl logs test-arcadedb-4` and grep
   for `SnapshotInstaller`. Log the result but do not fail on miss — log-line
   wording is not a stable contract.

Without persistence enabled, deleting the pod wipes its state, so the
recreated pod's Raft log starts at index 0. With the leader at >50 entries,
this is below the snapshot threshold gap and the leader will install a
snapshot rather than ship individual log entries.

## Phase Ordering

```
1. Existing: rollout
2. Existing: Raft consensus (3 pods)
3. Existing: write via leader
4. Existing: read back
5. P5: STATUS=HEALTHY (3 pods)
6. P6: leadership transfer + verify writes
7. P7: helm upgrade to replicaCount=5, re-verify quorum + STATUS
8. P8: delete pod, verify snapshot-install recovery
```

## CI Budget

| Phase | Estimate |
|-------|---------:|
| kind create | ~60 s |
| helm install + rollout | ~2 min |
| Existing phases 1–4 | ~2 min |
| P5 STATUS | ~5 s |
| P6 leadership transfer | ~60 s |
| P7 scale-up to 5 | ~3–5 min |
| P8 snapshot recovery | ~2 min |
| **Total** | **~11–13 min** |

Comfortable under the 20-minute job timeout.

## Risks and Mitigations

- **STATUS field absent on older image tags.** The chart's `image.tag` defaults
  to `appVersion`; if a release predates commit `203acdaac`, the STATUS field
  is missing. Mitigation: graceful skip with a warning, not a hard failure.
- **Leadership-transfer flake (Ratis re-elects the same pod).** Mitigation:
  send an explicit `peerId` instead of an empty body.
- **Scale-up rolling restart loses data.** Mitigation: do not assert data
  survival in P7; only assert cluster topology.
- **P8 is the most flake-prone phase.** It runs last so a P8 failure cannot
  mask earlier signals. If P8 proves flaky in practice, gate it behind a
  `RUN_SNAPSHOT_TEST=1` env var rather than disabling the rest of the file.

## Acceptance

The work is complete when:

1. `make test-integration` against a kind cluster passes all 8 phases on a
   chart pinned to an image tag that includes the STATUS column.
2. The same script run against an image tag that predates the STATUS column
   skips P5/P7's STATUS assertions with a warning and still passes the rest.
3. CI (`.github/workflows/lint.yml`) installs the chart with the
   `snapshotThreshold=50` override and runs the extended script in under
   the existing 20-minute job timeout.
4. The new helpers in `ci/integration-test.sh` are factored out and reused
   across phases (no duplicated port-forward/poll loops).
