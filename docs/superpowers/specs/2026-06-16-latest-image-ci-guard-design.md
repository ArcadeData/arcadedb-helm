# Latest-Image CI Guard — Design

**Date:** 2026-06-16
**Status:** Approved (design)

## Problem

The chart is pinned to a released ArcadeDB version (currently appVersion `26.6.1`,
image tag defaults to appVersion). All CI — `helm lint`, `helm-unittest`, and the
kind-based 6-phase HA integration suite — runs against that released image only.

When ArcadeDB ships a new release, the chart has had no signal about whether the
upcoming image still works with it. We want regressions in the *upcoming*
ArcadeDB build to surface **before** that version is officially released, while it
is only available as the rolling `latest` / `*-SNAPSHOT` image on Docker Hub.

## Goal

Add an ongoing CI job that continuously exercises the chart against the rolling
`latest` ArcadeDB image, using the existing full kind HA integration suite. The
job is **blocking** (a failure marks the workflow red) and runs on a schedule plus
manual dispatch. This is a permanent pre-release guard, not a one-off — after each
ArcadeDB release the chart bumps to the released tag and the guard keeps watching
the next cycle's `latest`.

Any breakage the guard surfaces is fixed as a follow-up chart change. That is the
"improve" half of the work, driven by whatever the job reveals.

## Non-Goals

- Changing the default image tag of the chart (stays pinned to appVersion).
- Blocking PRs on `latest` stability (the guard is its own scheduled workflow).
- Notifications/issue automation beyond GitHub's native red-workflow signal.
- Running `helm-unittest` against `latest`. The guard is integration-only by
  design (see below).

## Relationship to the version-pinned unit tests

`charts/arcadedb/tests/statefulset_test.yaml` pins the chart's `AppVersion` in an
`equal` assertion (e.g. `value: arcadedata/arcadedb:26.6.1`), because
`helm-unittest` cannot reference `Chart.AppVersion` inside an assertion value.

This pinning does **not** affect the guard:
- The guard runs the integration suite only — it never executes `helm-unittest`.
- The guard's `helm install` passes `--set image.tag=latest`, overriding the
  AppVersion default, so the pinned literal never collides with `latest`.

The pinning is instead a **release-bump** coupling, unrelated to this guard: it
must be updated in lockstep with `AppVersion`. See the checklist below.

### Release-bump checklist (when a new ArcadeDB version ships)

1. Bump `version` and `appVersion` in `charts/arcadedb/Chart.yaml`.
2. Update the pinned image literal(s) in
   `charts/arcadedb/tests/statefulset_test.yaml` to the new version, or
   `helm-unittest` will go red.
3. The `latest` guard keeps watching the next cycle's rolling image — no change
   needed.

## Approach

Chosen: **reusable workflow**. Extract the integration steps into a
`workflow_call` reusable workflow parameterized by image tag and pull policy. Both
the existing PR/push CI and the new scheduled guard call it, so the two runs
exercise byte-identical steps differing only by the image tag. This structurally
prevents the default-tag and latest-tag suites from diverging — the key risk for a
regression guard.

Rejected alternatives:
- *Standalone scheduled workflow that copies the integration job* — duplicated YAML
  drifts over time.
- *Matrix leg on the existing integration job* — conditional matrix gating couples
  the scheduled latest run to the PR workflow and is fiddly to reason about.

## Components

### 1. `.github/workflows/integration-reusable.yml`
- Trigger: `on: workflow_call`.
- Inputs:
  - `imageTag` (string, default `""`) — threaded to `--set image.tag`.
  - `pullPolicy` (string, default `IfNotPresent`) — threaded to `--set image.pullPolicy`.
- Body: the current `integration` job steps, lifted verbatim — install kind,
  install kubectl, set up Helm, create kind cluster, `helm install` (now with the
  two values threaded through), `make test-integration`, delete cluster
  (`if: always()`).
- Before the test run, log the resolved image digest of the tag under test so a red
  run identifies exactly which build broke.

### 2. `.github/workflows/lint.yml`
- `lint` and `unittest` jobs unchanged.
- `integration` job replaced by a single call:
  `uses: ./.github/workflows/integration-reusable.yml` with default inputs
  (released tag, `IfNotPresent`). Behavior is identical to today.

### 3. `.github/workflows/latest-image.yml`
- Triggers: `on: schedule` (weekly cron, matching the existing weekly Dependabot
  cadence) and `workflow_dispatch`.
- Single job that calls the reusable workflow with `imageTag: latest`,
  `pullPolicy: Always`.
- Blocking: a failure marks the workflow run red.

## Behavior Details

- `pullPolicy: Always` is required for `latest` so kind does not serve a stale
  cached layer.
- The digest-logging step makes red runs diagnosable against a moving tag.
- Weekly cron is the chosen default (changeable); manual `workflow_dispatch` allows
  on-demand runs.

## Verification

After wiring it up, trigger one manual `workflow_dispatch` run against `latest`
(currently the 26.7.1-SNAPSHOT build) to confirm the guard goes green, or to
capture the first real breakage.

Also confirm the refactored `integration` job in `lint.yml` still runs green on a
normal PR — the reusable extraction must not change existing behavior.

## Risks

- A red guard caused by upstream snapshot instability (not a chart problem) is
  expected and acceptable; it is the signal we want. Triage on failure.
- The reusable-workflow refactor touches passing CI; the verification step above
  guards against regressions in the default-tag path.
