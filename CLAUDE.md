# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

Official Helm chart for ArcadeDB. One chart lives in `charts/arcadedb/`; everything else is test tooling (`ci/`), CI workflows (`.github/workflows/`) and design notes (`docs/`).

## Working rules

- Never use the em dash character (`—`) in responses. Use a normal dash (`-`), a comma, or rephrase.
- Before changing anything, state how the change will be verified. Write the test first (a `tests/*_test.yaml` case before touching a template), then implement, then run every suite the change could affect. Do not report work as done until it has been tested.
- Reuse the existing `_helpers.tpl` helpers rather than adding new inline conditionals to templates.

## Commands

```bash
make lint               # helm lint
make test-unit          # helm-unittest suites + ci/check-failed-template.sh (installs plugin 0.5.2 if needed)
make test-config-seed   # runs files/config-seed.sh against sample files
make test-config-keys   # rendered -Darcadedb.* keys exist in the server image (Docker; IMAGE_TAG=... to pick another)
make test-integration   # kind end-to-end suite (ci/integration-test.sh) against an ALREADY INSTALLED release
make test               # all of the above
```

Run a single unit-test suite: `helm unittest charts/arcadedb -f 'tests/statefulset_test.yaml'`.
Render to inspect output: `helm template test charts/arcadedb --set replicaCount=3 -s templates/statefulset.yaml`.

`make test-integration` does not install anything: it expects a release named `test-arcadedb` in `default` on a kind cluster, installed the way `.github/workflows/integration-reusable.yml` ("Install chart" step) does, with env vars (`REPLICAS`, `IMAGE_FLAVOR`, `ROOT_PASSWORD_SECRET`/`_KEY`/`_FROM`, `CLUSTER_TOKEN_SECRET`/`_KEY`) describing that install. It is not idempotent; recreate the cluster between runs.

Running the kind suite locally:
- All HTTP calls go through `kubectl port-forward` on fixed local ports (2480, 2490-2494, 2500-2502). A local ArcadeDB or anything else listening there makes the forward fail and the suite go red for reasons unrelated to the chart. Check `lsof -nP -iTCP:2480-2502 -sTCP:LISTEN` before trusting a local failure.
- Skip `kind load docker-image` / `image-archive` (on macOS they fail with `ctr: content digest ... not found`) and let kubelet pull from Docker Hub.
- The image defaults to a 2 GB heap, so 3 pods don't fit an 8 GB Docker VM. Install with `--set-string 'arcadedb.extraEnvironment[0].name=ARCADEDB_OPTS_MEMORY' --set-string 'arcadedb.extraEnvironment[0].value=-Xms384M -Xmx768M'`. `make test-integration-gremlin` / `-gremlin-external` need a single-node release installed with the Gremlin plugin on a port and upgrade/restart it, so they are excluded from `make test`.

## Architecture

- **Everything renders through `templates/statefulset.yaml` + `templates/_helpers.tpl`.** The StatefulSet builds the server command line as `-Darcadedb.*` flags; most logic (credential routing, HA flags, plugin ports, TLS, storage plan, init containers, validation `fail`s) lives in named helpers in `_helpers.tpl`. Other templates are thin.
- **HA** is on when `replicaCount > 1` or autoscaling is enabled (`arcadedb.ha.enabled`): adds Raft flags, `serverList` built from the headless service, and a Raft storage dir. `podManagementPolicy: Parallel` is required for bootstrap. Scaling up via `helm upgrade` is not supported by the server (new peers aren't voted in).
- **Credential routing** (`arcadedb.credentials.*` helpers) has several branches that CI boots separately: root password as a mounted file (`rootPasswordPath`), optional HA cluster token file (`clusterTokenPath`), and the pre-26.11.1 HA fallback that passes the password as an env var named `arcadedb.server.rootPassword`. The branch depends on HA, whether a user Secret/token is given, and the image version parsed from the tag (`arcadedb.image.derivesTokenFromPasswordFile`; non-semver tags like `latest` count as older).
- **Storage plan** (`arcadedb.persistence.plan`, returned as JSON) decides PVC vs `emptyDir` for the reserved volumes `arcadedb-data`, `arcadedb-config`, `arcadedb-raft`; user `volumes`/`volumeClaimTemplates` entries for those names override it, except `emptyDir` entries, which persistence still wins over.
- **config-seed init container** (`files/config-seed.sh`): the config volume hides the image's `config/`, so this copies missing files (server-groups.json, gremlin-server.*) from the image without overwriting existing ones, and optionally rewrites the Gremlin `port:` (`writePortToConfig`). On the native flavor it runs from the JVM image because native images have no shell.
- **Image flavors**: `image.flavor: jvm|native`. Native has no `server.sh`, so the template invokes the binary directly and repeats the entrypoint flags; default tag becomes `<appVersion>-native`.
- **Logging** config ships from a ConfigMap mounted outside the config dir; a later `-Djava.util.logging.config.file` overrides the hidden one (last `-D` wins). The same "later flag wins" trick pins `-Duser.dir` for read-only rootfs.
- **Plugins** (`arcadedb.plugins.*`) each contribute ports, service ports, network policy rules and server parameters via `_arcadedb.plugin.*` helpers; a null plugin entry means disabled.

## Testing conventions

- Unit tests: `charts/arcadedb/tests/*_test.yaml` (helm-unittest 0.5.2, pinned in `Makefile`). `failedTemplate` assertions **must** use an exact `errorMessage`; `errorPattern` is silently ignored by 0.5.2 and a bare `failedTemplate` passes on any failure. `ci/check-failed-template.sh` enforces this and runs `tests/negative-control/`, where every assertion must fail.
- New `-Darcadedb.*` flags or env vars named after setting keys must exist in the server's `GlobalConfiguration` (`make test-config-keys`); the server ignores unknown keys silently. Exceptions go in `ci/config-keys-allowlist.txt` with a tracking issue.
- Each credential/Gremlin route has its own CI job in `.github/workflows/lint.yml`, all calling `integration-reusable.yml` with inputs. `latest-image.yml` runs the same suite weekly against `arcadedata/arcadedb:latest` as a blocking pre-release guard. A new route usually needs a job in both.
- When adding a value, document it in `values.yaml` (`## @param` comments) and in the hand-maintained `charts/arcadedb/README.md` parameter tables.

## Releases

- Version bump: `version` and `appVersion` in `Chart.yaml`, **and** the pinned image literal in `tests/statefulset_test.yaml` (helm-unittest can't reference `Chart.AppVersion`). Full checklist (temporary `imageTag: latest` override, the `26.11.1-SNAPSHOT` job to move, the pinned `26.10.2` env-route job to keep) is in the root `README.md` under "Release-bump checklist".
- Publishing: GitHub Actions → Release workflow (manual dispatch with version) → chart-releaser. The Helm repo `index.yaml` is served from the `gh-pages` branch.
- Commit style: `feat(#N): ...` / `fix(#N): ...` referencing the issue, squash-merged with the PR number.
