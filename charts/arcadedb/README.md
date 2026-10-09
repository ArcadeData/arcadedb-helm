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

| Name                                            | Description                   | Value |
|-------------------------------------------------|-------------------------------|-------|
| `arcadedb.credentials.rootPassword.secret.name` | Name of existing secret       | `nil` |
| `arcadedb.credentials.rootPassword.secret.key`  | Key to use in existing secret | `nil` |

### image

| Name               | Description                                                                                                                                                                                      | Value          |
|--------------------|--------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|----------------|
| `image.registry`   | Registry for image                                                                                                                                                                               | `arcadedata`   |
| `image.repository` | Image repo                                                                                                                                                                                       | `arcadedb`     |
| `image.pullPolicy` | This sets the pull policy for images.                                                                                                                                                            | `IfNotPresent` |
| `image.tag`        | Overrides the image tag whose default is the chart appVersion.                                                                                                                                   | `""`           |
| `imagePullSecrets` | This is for the secrets for pulling an image from a private repository more information can be found here: https://kubernetes.io/docs/tasks/configure-pod-container/pull-image-private-registry/ | `[]`           |

### initContainers

### initContainers.configDirectory

| Name                                       | Description                                                      | Value            |
|--------------------------------------------|------------------------------------------------------------------|------------------|
| `initContainers.configDirectory.image`     | Image for the generated config-chown init container              | `busybox:latest` |
| `initContainers.configDirectory.mountPath` | Mount path for the config volume in the generated init container |                  |
| `initContainers.configDirectory.volumeName`| Volume name mounted by the generated config-chown init container |                  |

### initContainers.otherContainers

| Name                              | Description                             | Value |
|-----------------------------------|-----------------------------------------|-------|
| `initContainers.otherContainers`  | Additional user-defined init containers | `[]` |

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
| `tls.bolt`                        | Bolt TLS mode: OPTIONAL or REQUIRED             | `OPTIONAL`             |
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
| `volumes`              | Pod volumes, rendered verbatim.                             | see `values.yaml` |
| `volumeClaimTemplates` | StatefulSet per-replica PVCs, rendered verbatim. Empty by default. | `[]`       |

### persistence

> **Not wired up.** Since the volumes refactor these values are only read by
> `NOTES.txt`; they no longer create any PVC. Use `volumeClaimTemplates` instead
> (see [Persistence](#persistence-1) below).

| Name                           | Description                                                                                      | Value           |
|--------------------------------|--------------------------------------------------------------------------------------------------|-----------------|
| `persistence.enabled`          | Persist the database directory with a PVC. Set false only for ephemeral/dev deployments.         | `true`          |
| `persistence.size`             | PVC size.                                                                                        | `8Gi`           |
| `persistence.accessMode`       | PVC access mode.                                                                                 | `ReadWriteOnce` |
| `persistence.storageClass`     | StorageClass name. Empty string uses the cluster default.                                        | `""`            |
| `persistence.config.enabled`   | Persist the config directory with a separate PVC.                                                | `false`         |
| `persistence.config.size`      | PVC size for the config directory.                                                               | `1Gi`           |
| `persistence.config.accessMode` | PVC access mode for the config directory.                                                        | `ReadWriteOnce` |
| `persistence.config.storageClass` | StorageClass name for the config PVC. Empty uses the cluster default.                        | `""`            |

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

Storage is fully value-driven: `volumes`, `volumeMounts`, and `volumeClaimTemplates` are rendered verbatim into the
StatefulSet. The chart ships five reserved volumes, mounted at the directories the server actually uses:

| Volume            | Mount path                 | Contents                      |
|-------------------|----------------------------|-------------------------------|
| `arcadedb-data`   | `/home/arcadedb/databases` | Databases                     |
| `arcadedb-config` | `/home/arcadedb/config`    | Users, tokens, server settings |
| `arcadedb-logs`   | `/home/arcadedb/log`       | Server logs                   |
| `arcadedb-tmp`    | `/tmp`                     | Scratch space                 |
| `arcadedb-raft`   | `/home/arcadedb/raft`      | Raft state (HA)               |

**All five default to `emptyDir`, so nothing survives a Pod restart out of the box.** To persist a directory, drop its
`emptyDir` entry from `volumes` and declare a `volumeClaimTemplates` entry of the same name — a StatefulSet auto-mounts a
per-replica volume matching the claim name, so `volumeMounts` needs no change:

```yaml
volumes:
  # arcadedb-data removed - backed by the claim template below
  - name: arcadedb-config
    emptyDir: {}
  - name: arcadedb-logs
    emptyDir: {}
  - name: arcadedb-tmp
    emptyDir: {}
  - name: arcadedb-raft
    emptyDir: {}

volumeClaimTemplates:
  - metadata:
      name: arcadedb-data
    spec:
      accessModes: [ReadWriteOnce]
      resources:
        requests:
          storage: 8Gi
```

For a durable HA cluster, give `arcadedb-config` and `arcadedb-raft` claim templates too. You can also add claim templates
under your own names (backups, replication) alongside a matching `volumeMounts` entry.

If you change `arcadedb.databaseDirectory`, `arcadedb.configDirectory`, `arcadedb.logsDirectory`, or
`ha.raftStorageDirectory`, update the corresponding `volumeMounts` path to match.

### Config Directory Permissions

ArcadeDB runs as a non-root user, but a newly mounted persistent volume may be owned by root. If ArcadeDB's config
directory is on that volume, it may not be able to write there. When either `arcadedb.backupConfigMap` or
`arcadedb.mcpConfigMap` is set, configure `initContainers.configDirectory.volumeName` and
`initContainers.configDirectory.mountPath` to the values used for the config directory 
to add an init container that will give the directory to the ArcadeDB user and group configured by
`securityContext.runAsUser` and `securityContext.runAsGroup`. 

It does not change ownership if the directory already exists. Both settings are required, and the generated container is omitted if neither config map is set.

The init container image defaults to `busybox:latest` and can be overridden with
`initContainers.configDirectory.image`. User-defined init containers in `initContainers.otherContainers` are also
rendered and follow the ownership container when it is generated.

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
