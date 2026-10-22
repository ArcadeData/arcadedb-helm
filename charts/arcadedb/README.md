# ArcadeDB Helm Chart

This Helm chart facilitates the deployment of [ArcadeDB](https://arcadedb.com/), an open-source multi-model database, on a
Kubernetes cluster.

## Prerequisites

- Kubernetes 1.19+
- Helm 3.0+

## Installation

To install the chart with the release name `my-arcadedb`:

```bash
helm install my-arcadedb ./arcadedb
```

The command deploys ArcadeDB on the Kubernetes cluster using the default configuration. The [Parameters](#parameters) section lists
the configurable parameters of this chart and their default values.

## Uninstallation

To uninstall/delete the `my-arcadedb` deployment:

```bash
helm uninstall my-arcadedb
```

The command removes all the Kubernetes components associated with the chart and deletes the release.

## Parameters

| Name                  | Description                                                                                         | Value                                                                                      |
|-----------------------|-----------------------------------------------------------------------------------------------------|--------------------------------------------------------------------------------------------|
| `fullnameOverride`    |                                                                                                     | `""`                                                                                       |
| `nameOverride`        | This is to override the chart name.                                                                 | `""`                                                                                       |
| `podAnnotations`      | Annotations added to every pod.                                                                     | `{}`                                                                                       |
| `podLabels`           | Labels added to every pod.                                                                          | `{}`                                                                                       |
| `podSecurityContext`  | Pod-level security context. UID/GID 1000 matches the arcadedb user in the Docker image.             | `{runAsNonRoot: true, fsGroup: 1000}`                                                       |
| `replicaCount`        | Number of replicas. Values greater than 1 enable Raft HA automatically.                             | `1`                                                                                        |
| `securityContext`     | Container-level security context.                                                                   | `{runAsUser: 1000, runAsGroup: 1000, allowPrivilegeEscalation: false, capabilities.drop: [ALL]}` |
| `statefulSetAnnotations` | Annotations added to the StatefulSet.                                                             | `{}`                                                                                       |
| `statefulSetLabels`   | Labels added to the StatefulSet.                                                                   | `{}`                                                                                       |

### arcadedb

| Name                                   | Description                                                        | Value                                    |
|----------------------------------------|--------------------------------------------------------------------|------------------------------------------|
| `arcadedb.configDirectory`             | Config storage directory inside the container                     | `/home/arcadedb/config`                  |
| `arcadedb.backupConfigMap`             | Name of the config map containing a [backup.json](https://docs.arcadedb.com/arcadedb/how-to/operations/auto-backup#configuration-file) configuration        |                                    |
| `arcadedb.mcpConfigMap`                | Name of the config map containing a [mcp-config.json](https://docs.arcadedb.com/arcadedb/reference/mcp/mcp#configuration) configuration        |                                    |
| `arcadedb.databaseDirectory`           | Database storage directory inside the container                   | `/home/arcadedb/databases`               |
| `arcadedb.defaultDatabases`            | Databases to create at startup. Empty = none.                     | `""`                                     |
| `arcadedb.extraCommands`               | Extra JVM -D arguments appended to the startup command            | `["-Darcadedb.server.mode=production"]`  |
| `arcadedb.extraEnvironment`            | Additional environment variables to pass to the ArcadeDB container | `[]`                                     |
| `arcadedb.logsDirectory`               | Directory where the server writes log files                       | `/home/arcadedb/log`                     |
| `arcadedb.installDirectory`            | Directory the ArcadeDB distribution lives in inside the image     | `/home/arcadedb`                         |
| `arcadedb.consoleWorkingDirectory`     | Writable working directory for interactive tools (console)        | `/tmp`                                   |
| `arcadedb.tmpDirectory`               | Writable dir for the PID file and `XDG_CACHE_HOME` (`""` = image defaults) | `/tmp`                         |
| `arcadedb.ha.raftStorageDirectory`     | Parent directory for per-node Raft storage                        | `/home/arcadedb/raft`                    |

### arcadedb.logging

The image keeps `arcadedb-log.properties` in its `config/` directory, which the `arcadedb-config` volume hides. Without
the file the server falls back to the copy bundled in its jar, which writes to a fixed `./log` and ignores
`arcadedb.logsDirectory`. The chart therefore ships the file in a ConfigMap (`<fullname>-logging`), mounts it read-only
at `arcadedb.logging.mountPath` and passes `-Djava.util.logging.config.file` pointing at it. Changing
`arcadedb.logging.properties` rolls the pods through a `checksum/logging` pod annotation.

| Name                          | Description                                                                                  | Value                                        |
|-------------------------------|----------------------------------------------------------------------------------------------|----------------------------------------------|
| `arcadedb.logging.enabled`    | Ship `arcadedb-log.properties` from a ConfigMap. `false` leaves logging to the image         | `true`                                       |
| `arcadedb.logging.mountPath`  | Directory the ConfigMap is mounted at. Must be outside `arcadedb.configDirectory`            | `/home/arcadedb/logging`                     |
| `arcadedb.logging.properties` | Content of `arcadedb-log.properties` (java.util.logging format)                              | the file packaged with ArcadeDB 26.10.2      |

`${arcadedb.server.logsDirectory}` in `java.util.logging.FileHandler.pattern` resolves to `arcadedb.logsDirectory`. An
`-Djava.util.logging.config.file` in `arcadedb.extraCommands` still takes precedence, since it comes later on the
command line. For example, to log at `FINE` to the console only:

```yaml
arcadedb:
  logging:
    properties: |
      handlers = java.util.logging.ConsoleHandler
      .level = INFO
      com.arcadedb.level = FINE
      java.util.logging.ConsoleHandler.level = FINE
      java.util.logging.ConsoleHandler.formatter = com.arcadedb.utility.AnsiLogFormatter
```

### arcadedb.plugins

Enable plugins by adding a plugin entry under `arcadedb.plugins`.

| Name                                      | Description                                             | Value                  |
|-------------------------------------------|---------------------------------------------------------|------------------------|
| `arcadedb.plugins`                        | Wire-protocol and metrics plugin configuration          | `{}`                   |
| `arcadedb.plugins.bolt.enabled`           | Enable Bolt protocol support                            | not set               |
| `arcadedb.plugins.bolt.port`              | Bolt protocol port                                      | `7687` when enabled   |
| `arcadedb.plugins.gremlin.enabled`        | Enable Gremlin protocol support                         | not set               |
| `arcadedb.plugins.gremlin.port`           | Gremlin protocol port                                   | `8182` when enabled  |
| `arcadedb.plugins.postgres.enabled`       | Enable PostgreSQL protocol support                      | not set               |
| `arcadedb.plugins.postgres.port`          | PostgreSQL protocol port                                | `5432` when enabled  |
| `arcadedb.plugins.mongo.enabled`          | Enable MongoDB protocol support                         | not set               |
| `arcadedb.plugins.mongo.port`             | MongoDB protocol port                                   | `27017` when enabled |
| `arcadedb.plugins.redis.enabled`          | Enable Redis protocol support                            | not set               |
| `arcadedb.plugins.redis.port`             | Redis protocol port                                     | `6379` when enabled  |
| `arcadedb.plugins.prometheus.enabled`     | Enable Prometheus metrics support                       | not set               |
| `arcadedb.plugins.prometheus.requireAuthentication` | Require authentication for Prometheus metrics | `true` when set       |
| `arcadedb.plugins.<custom>.enabled`       | Enable a custom plugin                                  | not set               |
| `arcadedb.plugins.<custom>.port`          | Custom plugin port, or `false` for a portless plugin   | required unless portless |
| `arcadedb.plugins.<custom>.class`         | Custom plugin implementation class                     | required              |

### arcadedb.credentials

| Name                                            | Description                                                                                                                       | Value                    |
|-------------------------------------------------|-----------------------------------------------------------------------------------------------------------------------------------|--------------------------|
| `arcadedb.credentials.rootPassword.secret.name` | Name of existing secret                                                                                                           | `nil`                    |
| `arcadedb.credentials.rootPassword.secret.key`  | Key to use in existing secret                                                                                                     | `nil`                    |
| `arcadedb.credentials.clusterToken.secret.name` | Existing secret holding the HA cluster token. `nil` uses the generated `clusterToken` key, or none with a user-supplied root password secret | `nil`                    |
| `arcadedb.credentials.clusterToken.secret.key`  | Key to use in the cluster token secret                                                                                            | `clusterToken`           |
| `arcadedb.credentials.mountPath`                | Directory the root password and cluster token are mounted at as files                                                            | `/etc/arcadedb/secrets`  |

#### Root password and HA cluster token

The root password is mounted from its Secret as a file and passed with `-Darcadedb.server.rootPasswordPath`, so it does
not appear in the process arguments (`/proc/<pid>/cmdline`, readable by anything in the pod). The `rootPassword`
environment variable is still set, for `extraCommands` that reference `$(rootPassword)`.

With HA active (`replicaCount > 1` or autoscaling), the nodes authenticate each other with a shared cluster token. Without
an explicit one, every node derives it from the root password and the cluster name with a fixed public salt, so a weak
root password makes it guessable and it cannot be rotated on its own. The chart mounts a dedicated token and passes
`-Darcadedb.ha.clusterTokenPath`:

- **Generated root password (default):** a random 64-character `clusterToken` key is added to
  `arcadedb-credentials-secret`, and kept across `helm upgrade` like the root password. Like the root password, it is
  regenerated on every render by `helm template` (e.g. ArgoCD); supply your own Secrets for GitOps workflows.
- **User-supplied root password Secret:** the token is opt-in, so an existing Secret without the key does not leave the
  pods stuck in `ContainerCreating`. Create one and point `arcadedb.credentials.clusterToken.secret` at it:

  ```shell
  kubectl create secret generic arcadedb-cluster-token --from-literal=clusterToken="$(openssl rand -hex 32)"
  helm upgrade ... --set arcadedb.credentials.clusterToken.secret.name=arcadedb-cluster-token
  ```

  Until then, on an image older than 26.11.1 the root password stays on the command line in HA mode: those servers
  derive the token from `arcadedb.server.rootPassword` only. From 26.11.1 the server derives it from the password file
  too, and the chart switches to the file whatever the token setting.

Upgrading an HA release from a chart version that did not mount a token changes the token. During the rolling restart
the restarted pods hold the new token and the others the old one, so commands forwarded between the two groups can be
rejected until the rollout completes. Rotating the token later (changing the Secret and restarting the StatefulSet)
behaves the same way.

### image

| Name               | Description                                                                                                                                                                                      | Value          |
|--------------------|--------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|----------------|
| `image.registry`   | Registry for image                                                                                                                                                                               | `arcadedata`   |
| `image.repository` | Image repo                                                                                                                                                                                       | `arcadedb`     |
| `image.pullPolicy` | This sets the pull policy for images.                                                                                                                                                            | `IfNotPresent` |
| `image.tag`        | Overrides the image tag whose default is the chart appVersion (`<appVersion>-native` when `image.flavor=native`).                                                                                | `""`           |
| `image.flavor`     | `jvm` or `native` (experimental GraalVM native binary). See [Native image](#native-image).                                                                                                       | `jvm`          |
| `imagePullSecrets` | This is for the secrets for pulling an image from a private repository more information can be found here: https://kubernetes.io/docs/tasks/configure-pod-container/pull-image-private-registry/ | `[]`           |

#### Native image

ArcadeDB also publishes an experimental GraalVM native build of the server
(`arcadedata/arcadedb:<version>-native`, multi-arch). It starts faster and uses
less memory than the JVM image. Select it with:

```bash
helm install my-arcadedb arcadedb/arcadedb --set image.flavor=native
```

The native image has no shell, so the chart starts `bin/arcadedb` directly instead
of `bin/server.sh`. Compared with the JVM flavor:

- Gremlin is not included, and custom plugin classes cannot be loaded. Enabling
  `arcadedb.plugins.gremlin` or a plugin with a `class:` fails the render.
- Environment variables that only `server.sh` reads (`JAVA_OPTS`,
  `ARCADEDB_OPTS_MEMORY`, `ARCADEDB_SETTINGS`) have no effect. Pass `-D` and heap
  flags through `arcadedb.extraCommands`, e.g. `-Xmx2g`.
- `bin/console.sh` and `kubectl exec ... sh` are not available in the pod.
- When you set `image.tag` yourself, choose the `image.flavor` that matches it
  (e.g. `image.tag=latest-native` with `image.flavor=native`).

### initContainers

| Name                                                  | Description                                                                                                  | Value             |
|-------------------------------------------------------|--------------------------------------------------------------------------------------------------------------|-------------------|
| `initContainers.configDirectory.volumeName`           | Name of the volume holding the config directory (e.g. a `volumeClaimTemplates` entry). Empty = no container. | `""`              |
| `initContainers.configDirectory.mountPath`            | Path that volume is mounted at in the ArcadeDB container: `arcadedb.configDirectory` or one of its parents.  | `""`              |
| `initContainers.configDirectory.image.registry`       | Registry for the config-chown image                                                                          | `docker.io`       |
| `initContainers.configDirectory.image.repository`     | Repository for the config-chown image                                                                        | `library/busybox` |
| `initContainers.configDirectory.image.tag`            | Tag for the config-chown image                                                                               | `1.37.0`          |
| `initContainers.configDirectory.image.pullPolicy`     | Pull policy for the config-chown image                                                                       | `IfNotPresent`    |
| `initContainers.otherContainers`                      | Additional init containers, rendered verbatim after config-chown                                             | `[]`              |

### serviceAccount

| Name                         | Description                                                                                          | Value  |
|------------------------------|------------------------------------------------------------------------------------------------------|--------|
| `serviceAccount.create`      | Specifies whether a service account should be created                                                 | `true`  |
| `serviceAccount.automount`   | Mount the ServiceAccount token into pods. ArcadeDB does not call the Kubernetes API - keep false.   | `false` |
| `serviceAccount.annotations` | Annotations to add to the service account                                                             | `{}`    |
| `serviceAccount.name`        | The name of the service account to use.                                                               | `""`   |

### Service

### http

| Name                | Description                                                                                                                                               | Value       |
|---------------------|-----------------------------------------------------------------------------------------------------------------------------------------------------------|-------------|
| `service.http.type` | Service type. Use LoadBalancer or configure ingress for external access.                                                                                  | `ClusterIP`  |
| `service.http.port` | This sets the ports. More information: https://kubernetes.io/docs/concepts/services-networking/service/#field-spec-ports                                 | `2480`      |

### https

| Name                | Description                 | Value |
|---------------------|-----------------------------|-------|
| `service.https.port` | HTTPS / Studio port        | `2490` |

### rpc

| Name               | Description                                      | Value  |
|--------------------|--------------------------------------------------|--------|
| `service.rpc.port` | Raft gRPC port (ha-raft subsystem).              | `2434` |

### external

| Name                       | Description                                      | Value          |
|----------------------------|--------------------------------------------------|----------------|
| `service.external.enabled` | Expose all protocol ports through an external Service | `false`    |
| `service.external.type`    | External Service type                            | `LoadBalancer` |

### tls

| Name                              | Description                                      | Value                  |
|-----------------------------------|--------------------------------------------------|------------------------|
| `tls.enabled`                     | Enable TLS and mount the certificate Secret     | `false`                |
| `tls.bolt`                        | Bolt TLS mode: DISABLED, OPTIONAL or REQUIRED   | `OPTIONAL`             |
| `tls.postgres`                    | PostgreSQL TLS mode: DISABLED, OPTIONAL or REQUIRED | `DISABLED`         |
| `tls.mountPath`                   | Certificate mount path inside the container     | `/etc/certs/arcadedb`  |
| `tls.secretRef.name`              | Secret containing TLS certificates (`""` = `<fullname>-tls`) | `""`      |
| `tls.secretRef.passwordSecret.name` | Secret holding the store password (`""` = root password secret) | `""` |
| `tls.secretRef.passwordSecret.key`  | Key inside `passwordSecret.name`              | `""`                   |
| `tls.secretRef.keyStore.key`      | KeyStore key in the Secret                      | `keystore.p12`         |
| `tls.secretRef.trustStore.format` | TrustStore format                               | `JKS`                  |
| `tls.secretRef.trustStore.key`    | TrustStore key in the Secret                   | `truststore.jks`       |
| `tls.certManager.enabled`         | Create a cert-manager Certificate resource     | `false`                |
| `tls.certManager.extraDnsNames`   | Adds extra DNS names to the TLS certificate     | `[]`                   |
| `tls.certManager.issuerProvidesCA` | Set `false` for issuers without a `ca.crt` (e.g. ACME): the key store doubles as trust store | `true` |
| `tls.certManager.issuerRef.kind`  | cert-manager issuer kind                       | `ClusterIssuer`        |
| `tls.certManager.issuerRef.name`  | cert-manager issuer name (required)            | `""`                   |

### ingress

This block is for setting up the ingress for more information can be found here: https://kubernetes.io/docs/concepts/services-networking/ingress/

| Name                  | Description | Value   |
|-----------------------|-------------|---------|
| `ingress.enabled`     |             | `false` |
| `ingress.className`   |             | `""`    |
| `ingress.annotations` |             | `{}`    |

### ingress.hosts

| Name                    | Description | Value                 |
|-------------------------|-------------|-----------------------|
| `ingress.hosts[0].host` |             | `chart-example.local` |

### ingress.hosts[0].paths

| Name                                 | Description | Value                    |
|--------------------------------------|-------------|--------------------------|
| `ingress.hosts[0].paths[0].path`     |             | `/`                      |
| `ingress.hosts[0].paths[0].pathType` |             | `ImplementationSpecific` |
| `ingress.tls`                        |             | `[]`                     |

### resources

| Name        | Description                  | Value |
|-------------|------------------------------|-------|
| `resources` | Resource requests and limits | `{}`  |

### livenessProbe

This is to setup the liveness and readiness probes more information can be found here: https://kubernetes.io/docs/tasks/configure-pod-container/configure-liveness-readiness-startup-probes/

### livenessProbe.httpGet

| Name                         | Description | Value            |
|------------------------------|-------------|------------------|
| `livenessProbe.httpGet.path` |             | `/api/v1/health` |
| `livenessProbe.httpGet.port` |             | `http`           |

### readinessProbe

This is to setup the liveness and readiness probes more information can be found here: https://kubernetes.io/docs/tasks/configure-pod-container/configure-liveness-readiness-startup-probes/

### readinessProbe.httpGet

| Name                          | Description | Value          |
|-------------------------------|-------------|----------------|
| `readinessProbe.httpGet.path` |             | `/api/v1/ready` |
| `readinessProbe.httpGet.port` |             | `http`         |

### autoscaling

This section is for setting up autoscaling more information can be found here: https://kubernetes.io/docs/concepts/workloads/autoscaling/

| Name                                         | Description                                                                                              | Value   |
|----------------------------------------------|----------------------------------------------------------------------------------------------------------|---------|
| `autoscaling.enabled`                        | Enable HorizontalPodAutoscaler. Server list is pre-sized to maxReplicas for KubernetesAutoJoin.         | `false` |
| `autoscaling.minReplicas`                    | Minimum replicas. Must satisfy Raft quorum: >= floor(maxReplicas/2)+1.                                   | `1`     |
| `autoscaling.maxReplicas`                    | Maximum replicas. Chart enforces quorum guard at render time.                                            | `5`     |
| `autoscaling.targetCPUUtilizationPercentage` |                                                                                                          | `80`    |

### storage

| Name                   | Description                                                | Value            |
|------------------------|------------------------------------------------------------|------------------|
| `volumeMounts`         | Pod volume mounts, rendered verbatim.                      | see `values.yaml` |
| `volumes`              | Pod volumes. Defaults back logs and `/tmp`; the data / config / Raft volumes come from `persistence`. | see `values.yaml` |
| `volumeClaimTemplates` | Extra per-replica PVCs, rendered after the ones generated from `persistence`. A reserved name replaces the generated claim. | `[]`       |

### persistence

Each enabled directory gets a generated per-replica `volumeClaimTemplates` entry; a disabled one falls back to an
`emptyDir` and `NOTES.txt` warns that its content is lost on Pod restart. See [Persistence](#persistence-1).

| Name                           | Description                                                                                      | Value           |
|--------------------------------|--------------------------------------------------------------------------------------------------|-----------------|
| `persistence.enabled`          | Persist the database directory with a PVC. Set false only for ephemeral/dev deployments.         | `true`          |
| `persistence.size`             | PVC size.                                                                                        | `8Gi`           |
| `persistence.accessMode`       | PVC access mode.                                                                                 | `ReadWriteOnce` |
| `persistence.storageClass`     | StorageClass name. Empty string uses the cluster default.                                        | `""`            |
| `persistence.config.enabled`   | Persist the config directory (users, groups, API tokens) with a separate PVC.                    | `true`          |
| `persistence.config.size`      | PVC size for the config directory.                                                               | `1Gi`           |
| `persistence.config.accessMode` | PVC access mode for the config directory.                                                        | `ReadWriteOnce` |
| `persistence.config.storageClass` | StorageClass name for the config PVC. Empty uses the cluster default.                        | `""`            |
| `persistence.raft.enabled`     | Persist the Raft log and snapshots with a separate PVC. Only rendered while HA is active.         | `true`          |
| `persistence.raft.size`        | PVC size for the Raft directory.                                                                 | `1Gi`           |
| `persistence.raft.accessMode`  | PVC access mode for the Raft directory.                                                          | `ReadWriteOnce` |
| `persistence.raft.storageClass` | StorageClass name for the Raft PVC. Empty uses the cluster default.                             | `""`            |

### networkPolicy

| Name                    | Description                                                                                                           | Value   |
|-------------------------|-----------------------------------------------------------------------------------------------------------------------|---------|
| `networkPolicy.enabled` | Create NetworkPolicy resources. Protocol ports are open to cluster traffic; Raft gRPC is restricted to ArcadeDB pods. | `false` |

### scheduling

| Name           | Description      | Value |
|----------------|------------------|-------|
| `nodeSelector` | Node selector    | `{}`  |
| `tolerations`  | Pod tolerations  | `[]`  |

### affinity

Set the anti-affinity selector scope to arcadedb servers.

| Name                                                                                  | Description | Value |
|---------------------------------------------------------------------------------------|-------------|-------|
| `affinity.podAntiAffinity.preferredDuringSchedulingIgnoredDuringExecution[0].weight` |             | `100` |

### extraManifests

| Name             | Description                                     | Value |
|------------------|-------------------------------------------------|-------|
| `extraManifests` | Include any amount of extra arbitrary manifests | `{}`  |

## observability

Opt-in, behavior-preserving observability (ArcadeDB 26.7.1+). Every knob below defaults off; existing deployments are unchanged.

### observability.metrics

| Name                                                                    | Description                                                   | Value                         |
|-------------------------------------------------------------------------|---------------------------------------------------------------|-------------------------------|
| `observability.metrics.prometheus.serviceMonitor.enabled`              | Create a Prometheus Operator ServiceMonitor                   | `false`                       |
| `observability.metrics.prometheus.serviceMonitor.interval`             | Scrape interval                                               | `30s`                         |
| `observability.metrics.prometheus.serviceMonitor.scrapeTimeout`        | Scrape timeout (empty = Prometheus default)                   | `""`                          |
| `observability.metrics.prometheus.serviceMonitor.path`                 | Metrics path                                                  | `/prometheus`                 |
| `observability.metrics.prometheus.serviceMonitor.labels`               | Extra labels (e.g. release: kube-prometheus-stack)            | `{}`                          |
| `observability.metrics.prometheus.serviceMonitor.annotations`          | Extra annotations                                             | `{}`                          |
| `observability.metrics.prometheus.serviceMonitor.relabelings`           | Prometheus relabelings                                        | `[]`                          |
| `observability.metrics.prometheus.serviceMonitor.metricRelabelings`     | Prometheus metric relabelings                                 | `[]`                          |
| `observability.metrics.prometheus.serviceMonitor.basicAuth.enabled`     | Scrape with basic auth                                        | `false`                       |
| `observability.metrics.prometheus.serviceMonitor.basicAuth.secretName`  | Secret with scrape credentials (username + password keys)     | `""`                          |
| `observability.metrics.prometheus.serviceMonitor.basicAuth.usernameKey` | Secret key holding the username                               | `username`                    |
| `observability.metrics.prometheus.serviceMonitor.basicAuth.passwordKey` | Secret key holding the password                               | `password`                    |
| `observability.metrics.prometheus.podAnnotations.enabled`              | Add prometheus.io/* scrape annotations to pods                | `false`                       |
| `observability.metrics.prometheus.podAnnotations.path`                 | Scrape path annotation value                                  | `/prometheus`                 |
| `observability.metrics.prometheus.podAnnotations.port`                 | Scrape port (empty = service.http.port)                       | `""`                          |
| `observability.metrics.otlp.enabled`                                   | Enable the OTLP metrics registry                              | `false`                       |
| `observability.metrics.otlp.endpoint`                                  | OTLP/HTTP metrics endpoint                                    | `http://localhost:4318/v1/metrics` |

### observability.tracing

| Name                              | Description                           | Value                   |
|-----------------------------------|---------------------------------------|-------------------------|
| `observability.tracing.enabled`   | Enable distributed tracing             | `false`                 |
| `observability.tracing.endpoint`  | OTLP/gRPC trace endpoint               | `http://localhost:4317` |
| `observability.tracing.samplingRate` | Parent-based sampling ratio [0.0, 1.0] | `0.0`              |

### observability.logging

| Name                                | Description                                              | Value   |
|-------------------------------------|----------------------------------------------------------|---------|
| `observability.logging.format`      | Log format: text or json                                 | `text`  |
| `observability.logging.includeTrace` | Append [traceId=…] to text logs while a trace is active | `false` |

### observability.health

| Name                                       | Description                                                                                                  | Value   |
|--------------------------------------------|--------------------------------------------------------------------------------------------------------------|---------|
| `observability.health.readinessRequiresHA` | /api/v1/ready waits for Raft join on HA clusters                                                            | `false` |
| `observability.health.readinessHAMaxLag`   | Max Raft log entries a follower may lag behind commit index and still report Ready (requires readinessRequiresHA) | `100` |

Specify each parameter using the `--set key=value[,key=value]` argument to `helm install`. For example:

```bash
helm install my-arcadedb ./arcadedb --set image.tag=21.11.1
```

Alternatively, a YAML file that specifies the values for the parameters can be provided while installing the chart. For example:

```bash
helm install my-arcadedb ./arcadedb -f values.yaml
```

## Persistence

The chart ships five reserved volumes, mounted (through `volumeMounts`) at the directories the server actually uses:

| Volume            | Mount path                 | Contents                       | Backed by default with                        |
|-------------------|----------------------------|--------------------------------|-----------------------------------------------|
| `arcadedb-data`   | `/home/arcadedb/databases` | Databases                      | PVC (`persistence.enabled`, 8Gi)              |
| `arcadedb-config` | `/home/arcadedb/config`    | Users, groups, tokens, settings | PVC (`persistence.config.enabled`, 1Gi)       |
| `arcadedb-raft`   | `/home/arcadedb/raft`      | Raft log and snapshots (HA)    | PVC while HA is active (`persistence.raft.enabled`, 1Gi), else `emptyDir` |
| `arcadedb-logs`   | `/home/arcadedb/log`       | Server logs                    | `emptyDir`                                    |
| `arcadedb-tmp`    | `/tmp`                     | Scratch space                  | `emptyDir`                                    |

For each enabled `persistence.*` directory the chart generates a per-replica `volumeClaimTemplates` entry of the same
name, which the StatefulSet mounts in place of a pod volume. Setting a flag to `false` backs that directory with an
`emptyDir` instead, and `NOTES.txt` warns that its content is lost when a Pod restarts. Raft storage is only used while
HA is active (`replicaCount > 1` or `autoscaling.enabled`), so a single node gets no Raft PVC.

To back a reserved directory yourself, either declare a `volumeClaimTemplates` entry with its name (it replaces the
generated claim, whatever the flag says), or add a non-`emptyDir` entry with its name to `volumes`, such as a
`hostPath` or an existing `persistentVolumeClaim`. An `emptyDir` entry for a reserved name in `volumes` is dropped
while its persistence flag is on, so a values file copied from an older chart, which listed all five as `emptyDir`,
still gets the PVCs.

```yaml
persistence:
  size: 50Gi
  storageClass: fast-ssd

volumeClaimTemplates:
  # extra per-replica claim under your own name, with a matching volumeMounts entry
  - metadata:
      name: arcadedb-backups
    spec:
      accessModes: [ReadWriteOnce]
      resources:
        requests:
          storage: 20Gi
```

### Upgrading from 26.10.2 or earlier

Charts from the volumes refactor (#19) up to 26.10.2 ignored `persistence.*` and kept databases, config and Raft
state on `emptyDir`, so those releases lose their data on every Pod restart. This chart moves them to PVCs, and a
StatefulSet's `volumeClaimTemplates` cannot change in place: `helm upgrade` fails with
`spec.volumeClaimTemplates: ... field is immutable`. To upgrade:

1. Back up every database you need (for example with `BACKUP DATABASE`, or by exporting it); the new PVCs start empty.
   Users and API tokens in the config directory are not carried over either.
2. Delete the StatefulSet and its Pods: `kubectl delete statefulset <release>-arcadedb`.
3. Run `helm upgrade`. The Pods are recreated with their PVCs.
4. Restore the databases and recreate users and tokens.

To keep the previous ephemeral behaviour instead, upgrade with `persistence.enabled=false`,
`persistence.config.enabled=false` and `persistence.raft.enabled=false`; nothing about the StatefulSet's claims
changes then. The same immutability applies later: turning a `persistence.*` flag on or off, changing a PVC size,
or switching between a single node and HA (which adds or removes the Raft claim) on an installed release needs the
StatefulSet recreated the same way. The PVCs themselves are kept when the StatefulSet or the release is deleted;
remove them with `kubectl delete pvc` once the data is no longer needed.

If you change `arcadedb.databaseDirectory`, `arcadedb.configDirectory`, `arcadedb.logsDirectory`, or
`ha.raftStorageDirectory`, update the corresponding `volumeMounts` path to match.
`arcadedb.configDirectory` is passed to the server as `-Darcadedb.server.configDirectory`, which needs ArcadeDB
26.10.1 or later: an older `image.tag` ignores it and keeps using `<rootPath>/config`. With
`readOnlyRootFilesystem` enabled, rendering fails if no `volumeMounts` entry covers that directory. A relocated
config directory starts empty apart from what the server writes itself (users, groups, tokens).

### Config Directory Permissions

ArcadeDB runs as a non-root user. When the config directory lives on a persistent volume, Kubernetes can create
it owned by root, typically while mounting `backup.json` or `mcp-config.json` (from `arcadedb.backupConfigMap` /
`arcadedb.mcpConfigMap`) into it. ArcadeDB then cannot write users or server settings and crash-loops.

Set `initContainers.configDirectory.volumeName` to the name of that volume and
`initContainers.configDirectory.mountPath` to the path it is mounted at in the ArcadeDB container (the
`mountPath` of its `volumeMounts` entry). The chart then adds a `config-chown` init container that mounts the
volume at the same path, creates `arcadedb.configDirectory` if it is missing, and chowns it to
`securityContext.runAsUser:securityContext.runAsGroup` (falling back to `podSecurityContext.fsGroup` for the
group). It chowns on every start, so it also repairs a directory that is already root-owned. Rendering fails if
`mountPath` is not `arcadedb.configDirectory` or one of its parents, or if `securityContext.runAsUser` is unset.

```yaml
# arcadedb-config is a generated PVC by default (persistence.config.enabled)
initContainers:
  configDirectory:
    volumeName: arcadedb-config
    mountPath: /home/arcadedb/config
```

The container runs as root with all capabilities dropped except `CHOWN` and `DAC_OVERRIDE`, so it is not
admitted in namespaces enforcing the `restricted` Pod Security Standard. Override
`initContainers.configDirectory.image` to pull from a private registry. Init containers listed in
`initContainers.otherContainers` are rendered verbatim after `config-chown`.

## Console

Run the interactive console inside a pod:

```bash
kubectl exec -it <release>-arcadedb-0 -- bin/console.sh
```

The console keeps a command history in `.history`, resolved against the JVM working directory. The image's working
directory is the install directory, which is unwritable because the chart defaults to
`securityContext.readOnlyRootFilesystem: true` — so the console would warn `Failed to save history` after every command.

To avoid that, the chart exports `ARCADEDB_SETTINGS=-Duser.dir=<arcadedb.consoleWorkingDirectory>`, which both
`bin/console.sh` and `bin/server.sh` splice into their `java` command line. The history file therefore lands in
`/tmp/.history`, backed by the ephemeral `arcadedb-tmp` volume, with `0600` permissions.

The server itself is unaffected: its startup command passes `-Duser.dir=<arcadedb.installDirectory>` after the
environment variable, so it keeps resolving `config/` and `backups/` exactly where it always has.

Point `arcadedb.consoleWorkingDirectory` at another writable mount to keep the history elsewhere, or set it to `""` to
drop both settings.

## TLS And Certificates.

TLS can be enabled for those protocols that support it by setting `tls.enabled` to `true`.

A key Store and trust Store are required from a secret. The keystore must be in `PKCS12` format.
The trust store defaults to `JKS` in line with Java defaults but `PKCS12` is supported - set `tls.secretRef.trustStore.format`.

The store password is read from a Secret and injected through the `TLS_STORE_PASSWORD` environment variable, so it never
appears in the pod spec. It defaults to the root password Secret; set `tls.secretRef.passwordSecret` to use another one.

The chart supports using `cert-manager` to create a certificate with the correct stores. Set the `tls.certManager` values
(`issuerRef.name` is required). The certificate covers the headless, `-http` and (when enabled) `-external` services plus
every pod FQDN; add more names with `tls.certManager.extraDnsNames`. cert-manager only writes `truststore.p12` when the
issuer returns a CA certificate, so for issuers that do not (e.g. ACME) set `tls.certManager.issuerProvidesCA` to `false`.

## Ingress And External Access

This chart provides support for exposing ArcadeDB outside the cluster:

1. Ingress resource. To enable Ingress, set `ingress.enabled` to `true` and configure the
`ingress.hosts` parameter. For example:

    ```yaml
    ingress:
      enabled: true
      hosts:
        - host: arcadedb.local
          paths: [ ]
    ```

1. HTTP service as `NodePort` or `LoadBalancer`. Set `service.http.type` accordingly.
1. All protocol ports as `NodePort` or `LoadBalancer`. Set `service.external.enabled` to `true`.
This exposes HTTP, HTTPS (if `tls.enabled` is `true`) and all plugins with a `port`.

## Resources

Resource requests and limits are unset by default for dev/Minikube compatibility. For production, set them via:

```yaml
resources:
  requests:
    cpu: 500m
    memory: 2Gi    # matches -Xms2G set by ARCADEDB_OPTS_MEMORY in the Docker image
  limits:
    memory: 4Gi    # no CPU limit - avoids throttling JVM GC pauses
```

## Notes

After installing the chart, you can access ArcadeDB by running the following command:

```bash
kubectl get --namespace default service arcadedb-http
```

Replace `arcadedb-http` with your release name if it's different. The command retrieves the service details, including the IP
address and port, which you can use to connect to ArcadeDB.
