# Latest-Image CI Guard Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a blocking, scheduled CI guard that runs the existing kind HA integration suite against the rolling `latest` ArcadeDB image, so regressions in the upcoming release surface before it ships.

**Architecture:** Extract the current `integration` job from `lint.yml` into a `workflow_call` reusable workflow parameterized by `imageTag` + `pullPolicy`. The existing CI calls it with defaults (released tag); a new scheduled workflow calls it with `latest`/`Always`. This keeps both runs byte-identical except the image tag.

**Tech Stack:** GitHub Actions (reusable workflows), Helm 4, kind, the repo's `make test-integration` (`ci/integration-test.sh`).

**Spec:** `docs/superpowers/specs/2026-06-16-latest-image-ci-guard-design.md`

**Verification tooling (already installed locally):** `actionlint` for workflow syntax/semantics, `helm` for render checks.

---

### Task 1: Reusable integration workflow

Lift the existing `integration` job into a reusable workflow, threading `imageTag`
and `pullPolicy` into the `helm install`. With default inputs it must behave
exactly as the current job (`arcadedata/arcadedb:26.6.1`, `IfNotPresent`).

**Files:**
- Create: `.github/workflows/integration-reusable.yml`

- [ ] **Step 1: Write the reusable workflow file**

Create `.github/workflows/integration-reusable.yml` with this exact content:

```yaml
name: Integration (reusable)

on:
  workflow_call:
    inputs:
      imageTag:
        description: "Image tag to test. Empty string defaults to chart appVersion."
        type: string
        default: ""
      pullPolicy:
        description: "Image pull policy (IfNotPresent for pinned, Always for rolling tags)."
        type: string
        default: "IfNotPresent"

permissions:
  contents: read

jobs:
  integration:
    runs-on: ubuntu-24.04
    timeout-minutes: 20
    steps:
      - name: Checkout
        uses: actions/checkout@de0fac2e4500dabe0009e67214ff5f5447ce83dd # v6.0.2

      - name: Install kind
        run: |
          curl -sLo /tmp/kind-linux-amd64 \
            https://kind.sigs.k8s.io/dl/v0.23.0/kind-linux-amd64
          curl -sLo /tmp/kind.sha256 \
            https://kind.sigs.k8s.io/dl/v0.23.0/kind-linux-amd64.sha256sum
          (cd /tmp && sha256sum -c kind.sha256)
          install -m 0755 /tmp/kind-linux-amd64 /usr/local/bin/kind

      - name: Install kubectl
        run: |
          curl -sLo /tmp/kubectl \
            "https://dl.k8s.io/release/v1.30.0/bin/linux/amd64/kubectl"
          curl -sLo /tmp/kubectl.sha256 \
            "https://dl.k8s.io/release/v1.30.0/bin/linux/amd64/kubectl.sha256"
          echo "$(cat /tmp/kubectl.sha256)  /tmp/kubectl" | sha256sum -c -
          install -m 0755 /tmp/kubectl /usr/local/bin/kubectl

      - name: Set up Helm
        uses: azure/setup-helm@dda3372f752e03dde6b3237bc9431cdc2f7a02a2 # v5.0.0
        with:
          version: v4.1.4

      - name: Log image digest under test
        if: inputs.imageTag != ''
        run: |
          echo "Testing image arcadedata/arcadedb:${{ inputs.imageTag }}"
          docker buildx imagetools inspect "arcadedata/arcadedb:${{ inputs.imageTag }}" || true

      - name: Create kind cluster
        run: kind create cluster --wait 60s

      - name: Install chart
        run: |
          helm install test-arcadedb charts/arcadedb/ \
            --set replicaCount=3 \
            --set persistence.enabled=false \
            --set arcadedb.defaultDatabases="" \
            --set image.tag="${{ inputs.imageTag }}" \
            --set image.pullPolicy="${{ inputs.pullPolicy }}" \
            --timeout 5m \
            --wait

      - name: Run integration tests
        run: make test-integration

      - name: Delete kind cluster
        if: always()
        run: kind delete cluster
```

- [ ] **Step 2: Validate workflow syntax**

Run: `actionlint .github/workflows/integration-reusable.yml`
Expected: no output (exit 0).

- [ ] **Step 3: Verify the embedded install command threads values correctly**

This proves the `--set` flags produce the right image with default inputs. Run:

```bash
helm template t charts/arcadedb \
  --set persistence.enabled=false \
  --set image.tag="" \
  --set image.pullPolicy=IfNotPresent \
  | grep -E 'image:|imagePullPolicy:' | sort -u
```

Expected output:
```
          image: "arcadedata/arcadedb:26.6.1"
          imagePullPolicy: IfNotPresent
```

- [ ] **Step 4: Commit**

```bash
git add .github/workflows/integration-reusable.yml
git commit -m "ci: add reusable integration workflow parameterized by image tag"
```

---

### Task 2: Refactor `lint.yml` integration job to call the reusable workflow

Replace the inline `integration` job (steps-based) with a single `uses:` call so
the existing CI runs through the reusable workflow with defaults. `lint` and
`unittest` jobs are untouched.

**Files:**
- Modify: `.github/workflows/lint.yml:41-88` (the entire `integration:` job)

- [ ] **Step 1: Replace the integration job**

In `.github/workflows/lint.yml`, replace the whole `integration:` job (currently
lines 41-88, starting at `  integration:` and ending at the final
`        run: kind delete cluster`) with exactly:

```yaml
  integration:
    uses: ./.github/workflows/integration-reusable.yml
```

Leave everything above it (`lint` and `unittest` jobs, `on:`, `permissions:`)
unchanged.

- [ ] **Step 2: Validate workflow syntax**

Run: `actionlint .github/workflows/lint.yml`
Expected: no output (exit 0).

- [ ] **Step 3: Confirm the default render is unchanged**

Run:
```bash
helm template t charts/arcadedb --set persistence.enabled=false \
  | grep -E 'image:|imagePullPolicy:' | sort -u
```
Expected output:
```
          image: "arcadedata/arcadedb:26.6.1"
          imagePullPolicy: IfNotPresent
```

- [ ] **Step 4: Commit**

```bash
git add .github/workflows/lint.yml
git commit -m "ci: run integration job via reusable workflow"
```

---

### Task 3: Scheduled latest-image guard workflow

A new workflow that runs weekly (and on manual dispatch), calling the reusable
workflow against the rolling `latest` image with `Always` pull policy. Blocking by
default — a failure marks the run red.

**Files:**
- Create: `.github/workflows/latest-image.yml`

- [ ] **Step 1: Write the guard workflow file**

Create `.github/workflows/latest-image.yml` with this exact content:

```yaml
name: CI - Latest Image Guard

# Pre-release guard: exercises the chart against the rolling `latest` ArcadeDB
# image so regressions in the upcoming release surface before it ships.
on:
  schedule:
    - cron: "0 6 * * 1" # weekly, Monday 06:00 UTC (matches Dependabot cadence)
  workflow_dispatch:

permissions:
  contents: read

jobs:
  integration-latest:
    uses: ./.github/workflows/integration-reusable.yml
    with:
      imageTag: latest
      pullPolicy: Always
```

- [ ] **Step 2: Validate workflow syntax**

Run: `actionlint .github/workflows/latest-image.yml`
Expected: no output (exit 0).

- [ ] **Step 3: Verify the latest-tag render is correct**

Confirms the values the guard passes produce the expected image. Run:
```bash
helm template t charts/arcadedb --set persistence.enabled=false \
  --set image.tag=latest --set image.pullPolicy=Always \
  | grep -E 'image:|imagePullPolicy:' | sort -u
```
Expected output:
```
          image: "arcadedata/arcadedb:latest"
          imagePullPolicy: Always
```

- [ ] **Step 4: Commit**

```bash
git add .github/workflows/latest-image.yml
git commit -m "ci: add weekly latest-image regression guard"
```

---

### Task 4: Document the guard and the release-bump coupling

Surface the guard in the README's CI/Development section and record the
release-bump checklist (bumping appVersion requires bumping the pinned literal in
`statefulset_test.yaml`).

**Files:**
- Modify: `README.md` (Development / CI section)

- [ ] **Step 1: Locate the CI/Development section**

Run: `grep -n "Development\|lint\|test-integration\|CI" README.md`
Expected: shows the line numbers of the Development section that documents the
`make` targets and CI jobs.

- [ ] **Step 2: Add the guard + checklist documentation**

Under the Development/CI section (after the existing description of the lint /
unittest / integration jobs), add this Markdown:

```markdown
### Latest-image guard

`.github/workflows/latest-image.yml` runs the full kind HA integration suite
against the rolling `arcadedata/arcadedb:latest` image every Monday (and on
manual `workflow_dispatch`). It is a **blocking** pre-release guard: a red run
means the upcoming ArcadeDB release breaks the chart. It shares its steps with
the PR integration job via `.github/workflows/integration-reusable.yml`, so both
exercise an identical suite differing only by image tag.

### Release-bump checklist

When a new ArcadeDB version is released:

1. Bump `version` and `appVersion` in `charts/arcadedb/Chart.yaml`.
2. Update the pinned image literal in `charts/arcadedb/tests/statefulset_test.yaml`
   to the new version, or `helm-unittest` will fail (it cannot reference
   `Chart.AppVersion` in an assertion).
3. The latest-image guard needs no change — it keeps watching the next cycle's
   rolling image.
```

- [ ] **Step 3: Verify the README still renders as valid Markdown**

Run: `python3 -c "import pathlib; print(len(pathlib.Path('README.md').read_text()))"`
Expected: prints a number greater than before (no exception = file readable).

- [ ] **Step 4: Commit**

```bash
git add README.md
git commit -m "docs: document latest-image guard and release-bump checklist"
```

---

### Task 5: Post-merge live verification (manual)

The reusable-workflow `uses:` reference resolves against the default branch, so
the guard can only be triggered after these changes land on `main`. This task is a
manual checklist, not an automated test.

- [ ] **Step 1: After merge, trigger the guard manually**

Run: `gh workflow run "CI - Latest Image Guard"`
Expected: command succeeds (queues a run).

- [ ] **Step 2: Watch the run**

Run: `gh run watch $(gh run list --workflow="CI - Latest Image Guard" --limit 1 --json databaseId --jq '.[0].databaseId')`
Expected: the run completes. Green = chart works against the upcoming image.
Red = first real breakage; inspect the "Log image digest under test" step output
to identify which `latest` build broke, then open a follow-up to fix the chart.

- [ ] **Step 3: Confirm normal PR CI is unaffected**

Verify the most recent `CI - Lint, Unit Tests, Integration Tests` run on the merge
commit is green, confirming the reusable extraction did not regress the
default-tag integration path.

Run: `gh run list --workflow="CI - Lint, Unit Tests, Integration Tests" --limit 1`
Expected: latest run shows `completed  success`.
