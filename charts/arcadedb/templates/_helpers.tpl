{{/*
Expand the name of the chart.
*/}}
{{- define "arcadedb.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
We truncate at 63 chars because some Kubernetes name fields are limited to this (by the DNS naming spec).
If release name contains chart name it will be used as a full name.
*/}}
{{- define "arcadedb.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := default .Chart.Name .Values.nameOverride }}
{{- if contains $name .Release.Name }}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}
{{- end }}

{{/*
Create chart name and version as used by the chart label.
*/}}
{{- define "arcadedb.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "arcadedb.labels" -}}
app: {{ .Chart.Name }}
helm.sh/chart: {{ include "arcadedb.chart" . }}
{{ include "arcadedb.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "arcadedb.selectorLabels" -}}
app.kubernetes.io/name: {{ include "arcadedb.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Create the name of the service account to use
*/}}
{{- define "arcadedb.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "arcadedb.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{/*
Returns "true" when image.flavor selects the GraalVM native image, "" for the
JVM image. Fails on any other flavor so a typo cannot silently fall back to jvm.
*/}}
{{- define "arcadedb.native" -}}
{{- $flavor := .Values.image.flavor | default "jvm" -}}
{{- if not (has $flavor (list "jvm" "native")) -}}
  {{- fail (printf "image.flavor must be 'jvm' or 'native', got '%s'." $flavor) -}}
{{- end -}}
{{- if eq $flavor "native" -}}true{{- end -}}
{{- end }}

{{/*
Image tag: image.tag when set, else the chart appVersion, suffixed with
-native for the native flavor (the upstream multi-arch native manifest).
*/}}
{{- define "arcadedb.image.tag" -}}
{{- if .Values.image.tag -}}
{{- .Values.image.tag -}}
{{- else if include "arcadedb.native" . -}}
{{- printf "%s-native" .Chart.AppVersion -}}
{{- else -}}
{{- .Chart.AppVersion -}}
{{- end -}}
{{- end }}

{{/*
 Creates kubernetes naming suffix.
*/}}
{{- define "arcadedb.k8sSuffix" -}}
{{- $fullname := (include "arcadedb.fullname" .) -}}
{{- printf ".%s.%s.svc.cluster.local" $fullname .Release.Namespace -}}
{{- end }}

{{/*
Create a comma-separated list of StatefulSet pod FQDNs (no ports).
When HPA is enabled, the list is sized to autoscaling.maxReplicas so that
KubernetesAutoJoin can resolve any pod ordinal up to the maximum scale.
*/}}
{{- define "arcadedb.nodehosts" -}}
{{- $replicas := int .Values.replicaCount -}}
{{- if and .Values.autoscaling.enabled (gt (int .Values.autoscaling.maxReplicas) $replicas) -}}
  {{- $replicas = int .Values.autoscaling.maxReplicas -}}
{{- end -}}
{{- $names := list -}}
{{- $fullname := (include "arcadedb.fullname" .) -}}
{{- $k8sSuffix := (include "arcadedb.k8sSuffix" .) -}}
{{- range $i, $_ := until $replicas }}
{{- $names = append $names (printf "%s-%d%s" $fullname $i $k8sSuffix) }}
{{- end }}
{{- join "," $names -}}
{{- end }}

{{/*
Create the Raft HA server list: host:raftPort:httpPort per pod, plus
:priority:httpsPort when TLS is on. Declaring the ports keeps peer HTTP/HTTPS
endpoints explicit instead of relying on ArcadeDB's local-port fallback.
*/}}
{{- define "arcadedb.nodenames" -}}
{{- $ports := printf "%d:%d" (int .Values.service.rpc.port) (int .Values.service.http.port) -}}
{{- if .Values.tls.enabled -}}
  {{- $ports = printf "%s:0:%d" $ports (int .Values.service.https.port) -}}
{{- end -}}
{{- $names := list -}}
{{- range $host := split "," (include "arcadedb.nodehosts" .) }}
{{- $names = append $names (printf "%s:%s" $host $ports) }}
{{- end }}
{{- join "," $names -}}
{{- end }}

{{/*
Preparing a list of plugin ports to build plugin configurations.
A plugin entry left empty (null) is treated as disabled; the plugin
parameters, service and networkPolicy helpers build on this output.
*/}}
{{- define "_arcadedb.plugin.ports" -}}
  {{- $native := include "arcadedb.native" . -}}
  {{- range $plugin, $entry := .Values.arcadedb.plugins | default dict -}}
    {{- $config := $entry | default dict }}
    {{- if $config.enabled }}
      {{- if $native }}
        {{/*
        The native binary bundles a fixed module set: Gremlin is left out of it and
        there is no classpath to load extra plugin jars from. The server would skip
        such a plugin without a log line, so refuse to render instead.
        */}}
        {{- if eq $plugin "gremlin" }}
          {{- fail "The gremlin plugin is not included in the native image (image.flavor=native). Disable arcadedb.plugins.gremlin or use image.flavor=jvm." -}}
        {{- else if not (has $plugin (list "bolt" "postgres" "mongo" "redis" "prometheus")) }}
          {{- fail (printf "Custom plugin '%s' cannot be loaded by the native image (image.flavor=native): the binary has no classpath for extra plugin jars. Disable it or use image.flavor=jvm." $plugin) -}}
        {{- end }}
      {{- end }}
      {{- $port := int 0}}
      {{- if eq $plugin "bolt" }}
        {{- $port = default 7687 $config.port }}
      {{- else if eq $plugin "gremlin" }}
        {{- $port = default 8182 $config.port }}
      {{- else if eq $plugin "postgres" }}
        {{- $port = default 5432 $config.port }}
      {{- else if eq $plugin "mongo" }}
        {{- $port = default 27017 $config.port }}
      {{- else if eq $plugin "redis" }}
        {{- $port = default 6379 $config.port }}
      {{- else if eq $plugin "prometheus" }}
        {{/*
        Prometheus does not use a port in the plugin configuration. It is accessible from /prometheus endpoint.
        */}}
        {{- $port = -1 }}
      {{- else }}
        {{- if not (hasKey $config "port") }}
          {{- fail (printf "Custom plugin '%s' has no port specified." $plugin) -}}
        {{- end }}
        {{- if not $config.class }}
          {{- fail (printf "Custom plugin '%s' has no class specified." $plugin) -}}
        {{- end }}
        {{/*
        port: false declares a plugin that listens on nothing, the same -1 sentinel prometheus uses above.
        */}}
        {{- if $config.port }}
          {{- $port = $config.port }}
        {{- else }}
          {{- $port = -1 }}
        {{- end }}
      {{- end }}
{{ $plugin }}:
  port: {{ $port }}
  class: {{ default "" $config.class }}
    {{- end }}
  {{- end }}
{{- end }}

{{/*
Create a comma separated list of plugins to be enabled in arcadedb
*/}}
{{- define "arcadedb.plugin.parameters" -}}
{{- $plugins := list -}}
{{- $params := list -}}
  {{- range $plugin, $config := (include "_arcadedb.plugin.ports" . | fromYaml) -}}
    {{- if eq $plugin "bolt" -}}
      {{- $plugins = append $plugins "Bolt:com.arcadedb.bolt.BoltProtocolPlugin" -}}
      {{- $params = append $params (printf "-Darcadedb.bolt.port=%d" (int $config.port)) -}}
    {{- else if eq $plugin "gremlin" -}}
      {{- $plugins = append $plugins "GremlinServer:com.arcadedb.server.gremlin.GremlinServerPlugin" -}}
      {{- $params = append $params (printf "-Darcadedb.gremlin.port=%d" (int $config.port)) -}}
    {{- else if eq $plugin "postgres" -}}
      {{- $plugins = append $plugins "Postgres:com.arcadedb.postgres.PostgresProtocolPlugin" -}}
      {{- $params = append $params (printf "-Darcadedb.postgres.port=%d" (int $config.port)) -}}
    {{- else if eq $plugin "mongo" -}}
      {{- $plugins = append $plugins "MongoDB:com.arcadedb.mongo.MongoDBProtocolPlugin" -}}
      {{- $params = append $params (printf "-Darcadedb.mongo.port=%d" (int $config.port)) -}}
    {{- else if eq $plugin "redis" -}}
      {{- $plugins = append $plugins "Redis:com.arcadedb.redis.RedisProtocolPlugin" -}}
      {{- $params = append $params (printf "-Darcadedb.redis.port=%d" (int $config.port)) -}}
    {{- else if eq $plugin "prometheus" -}}
      {{- $plugins = append $plugins "Prometheus:com.arcadedb.metrics.prometheus.PrometheusMetricsPlugin" -}}
      {{- with $.Values.arcadedb.plugins.prometheus -}}
        {{- if hasKey . "requireAuthentication" -}}
          {{- $params = append $params (printf "-Darcadedb.serverMetrics.prometheus.requireAuthentication=%v" .requireAuthentication) -}}
        {{- end -}}
      {{- end -}}
    {{- else -}}
      {{- $plugins = append $plugins (printf "%s:%s" $plugin $config.class) -}}
    {{- end -}}
  {{- end -}}
{{- $o := .Values.observability | default dict -}}
{{- $otlp := (($o.metrics | default dict).otlp) | default dict -}}
{{- $tracing := $o.tracing | default dict -}}
{{- if $otlp.enabled -}}
  {{- $plugins = append $plugins "Otlp:com.arcadedb.metrics.otlp.OtlpMetricsPlugin" -}}
{{- end -}}
{{- if $tracing.enabled -}}
  {{- $plugins = append $plugins "Tracing:com.arcadedb.tracing.TracingPlugin" -}}
{{- end -}}
{{- if gt (len $plugins) 0 -}}
- -Darcadedb.server.plugins={{ join "," $plugins }}
{{- end -}}
{{ range $param := $params }}
- {{ $param }}
{{- end -}}
{{- end -}}

{{/*
Create service configuration for the enabled plugins
*/}}
{{- define "arcadedb.plugin.service" -}}
  {{- $plugins := (include "_arcadedb.plugin.ports" . | fromYaml) }}
  {{- range $plugin, $config := $plugins }}
    {{- if (gt (int $config.port) 0) }}
- port: {{ $config.port }}
  targetPort: {{ $config.port }}
  protocol: TCP
  name: {{ $plugin }}-port
    {{- end -}}
  {{- end -}}
{{- end -}}

{{/*
Create network policy configuration for the enabled plugins
*/}}
{{- define "arcadedb.plugin.networkPolicy" -}}
  {{- $plugins := (include "_arcadedb.plugin.ports" . | fromYaml) }}
  {{- range $plugin, $config := $plugins }}
    {{- if (gt (int $config.port) 0) }}
- port: {{ $config.port }}
  protocol: TCP
    {{- end -}}
  {{- end -}}
{{- end -}}

{{/*
Observability -D JVM args (logging, OTLP metrics, tracing, readiness).
All opt-in; emits nothing when defaults are unchanged.
*/}}
{{- define "arcadedb.observability.args" -}}
{{- $o := .Values.observability | default dict -}}
{{- $logging := $o.logging | default dict -}}
{{- $otlp := (($o.metrics | default dict).otlp) | default dict -}}
{{- $tracing := $o.tracing | default dict -}}
{{- $health := $o.health | default dict -}}
{{- if eq $logging.format "json" }}
- -Darcadedb.server.logFormat=json
{{- end }}
{{- if $logging.includeTrace }}
- -Darcadedb.server.logIncludeTrace=true
{{- end }}
{{- if $otlp.enabled }}
- -Darcadedb.serverMetrics.otlp.enabled=true
- -Darcadedb.serverMetrics.otlp.endpoint={{ $otlp.endpoint }}
{{- end }}
{{- if $tracing.enabled }}
- -Darcadedb.serverMetrics.tracing.enabled=true
- -Darcadedb.serverMetrics.tracing.endpoint={{ $tracing.endpoint }}
- -Darcadedb.serverMetrics.tracing.samplingRate={{ $tracing.samplingRate }}
{{- end }}
{{- if $health.readinessRequiresHA }}
- -Darcadedb.server.readinessRequiresHA=true
- -Darcadedb.server.readinessHAMaxLag={{ $health.readinessHAMaxLag }}
{{- end }}
{{- end -}}

{{/*
Name of the secret holding the TLS key store / trust store.
*/}}
{{- define "arcadedb.tls.secretName" -}}
{{- default (printf "%s-tls" (include "arcadedb.fullname" .)) .Values.tls.secretRef.name -}}
{{- end -}}

{{/*
Secret name and key holding the key store / trust store password.
Defaults to the root password secret.
*/}}
{{- define "arcadedb.tls.passwordSecretName" -}}
{{- with .Values.tls.secretRef.passwordSecret.name -}}
{{- . -}}
{{- else -}}
{{- default "arcadedb-credentials-secret" .Values.arcadedb.credentials.rootPassword.secret.name -}}
{{- end -}}
{{- end -}}

{{- define "arcadedb.tls.passwordSecretKey" -}}
{{- if .Values.tls.secretRef.passwordSecret.name -}}
{{- required "tls.secretRef.passwordSecret.key is required when tls.secretRef.passwordSecret.name is set" .Values.tls.secretRef.passwordSecret.key -}}
{{- else if .Values.arcadedb.credentials.rootPassword.secret.name -}}
{{- .Values.arcadedb.credentials.rootPassword.secret.key -}}
{{- else -}}
rootPassword
{{- end -}}
{{- end -}}

{{/*
TLS parameters. Store passwords come from the TLS_STORE_PASSWORD env var
(a secretKeyRef), so they never appear in the pod spec.
*/}}
{{- define "arcadedb.tls.parameters" -}}
{{- if .Values.tls.enabled }}
- -Darcadedb.ssl.enabled=true
- -Darcadedb.server.httpsIncomingPort={{ .Values.service.https.port }}
  {{- range $plugin := list "bolt" "postgres" }}
    {{- if (get ($.Values.arcadedb.plugins | default dict) $plugin | default dict).enabled }}
      {{- $mode := upper (toString (get $.Values.tls $plugin)) }}
      {{- if not (has $mode (list "DISABLED" "OPTIONAL" "REQUIRED")) }}
        {{- fail (printf "tls.%s must be DISABLED, OPTIONAL or REQUIRED (got %q)" $plugin (toString (get $.Values.tls $plugin))) }}
      {{- end }}
- -Darcadedb.{{ $plugin }}.ssl={{ $mode }}
    {{- end }}
  {{- end }}
  {{- $keyStoreKey := .Values.tls.secretRef.keyStore.key }}
  {{- $trustStoreKey := .Values.tls.secretRef.trustStore.key }}
  {{- $trustStoreFormat := .Values.tls.secretRef.trustStore.format }}
  {{- if .Values.tls.certManager.enabled }}
    {{- $keyStoreKey = "keystore.p12" -}}
    {{- $trustStoreFormat = "PKCS12" -}}
    {{- /* cert-manager only writes truststore.p12 when the issuer returns a CA */ -}}
    {{- $trustStoreKey = ternary "truststore.p12" "keystore.p12" .Values.tls.certManager.issuerProvidesCA -}}
  {{- end }}
  {{- if ne "JKS" $trustStoreFormat }}
- -Djavax.net.ssl.trustStoreType={{ $trustStoreFormat }}
  {{- end }}
- -Darcadedb.ssl.keyStore={{ printf "%s/%s" .Values.tls.mountPath $keyStoreKey }}
- -Darcadedb.ssl.keyStorePassword=$(TLS_STORE_PASSWORD)
- -Darcadedb.ssl.trustStore={{ printf "%s/%s" .Values.tls.mountPath $trustStoreKey }}
- -Darcadedb.ssl.trustStorePassword=$(TLS_STORE_PASSWORD)
{{- end }}
{{- end -}}

{{/*
Guard: the server writes users, groups and tokens to arcadedb.configDirectory. Under
readOnlyRootFilesystem that path must be backed by one of the volumeMounts, which are
rendered verbatim and do not follow configDirectory on their own.
*/}}
{{- define "arcadedb.configDirectory.validate" -}}
{{- if (.Values.securityContext | default dict).readOnlyRootFilesystem -}}
{{- $configDir := trimSuffix "/" .Values.arcadedb.configDirectory -}}
{{- $mounted := false -}}
{{- range .Values.volumeMounts -}}
{{- $mountPath := trimSuffix "/" (toString .mountPath) -}}
{{- if or (eq $configDir $mountPath) (hasPrefix (printf "%s/" $mountPath) $configDir) -}}
{{- $mounted = true -}}
{{- end -}}
{{- end -}}
{{- if not $mounted -}}
{{- fail (printf "arcadedb.configDirectory (%s) is not on any volumeMounts entry, so the server cannot write users or tokens under readOnlyRootFilesystem: update the arcadedb-config mountPath in volumeMounts to match" .Values.arcadedb.configDirectory) -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{/*
Logging configuration (issue #38). The image keeps arcadedb-log.properties in
its config/ directory, which the arcadedb-config volume hides; the chart ships
the file from a ConfigMap mounted outside configDirectory instead.

arcadedb.logging.enabled returns "true" when the chart ships the file, "" when
arcadedb.logging is off or null.
*/}}
{{- define "arcadedb.logging.enabled" -}}
{{- if (.Values.arcadedb.logging | default dict).enabled -}}true{{- end -}}
{{- end -}}

{{- define "arcadedb.logging.configMapName" -}}
{{- printf "%s-logging" (include "arcadedb.fullname" .) | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "arcadedb.logging.properties" -}}
{{- required "arcadedb.logging.properties must hold the arcadedb-log.properties content when arcadedb.logging.enabled is true" .Values.arcadedb.logging.properties | toString -}}
{{- end -}}

{{- define "arcadedb.logging.mountPath" -}}
{{- $mountPath := trimSuffix "/" (required "arcadedb.logging.mountPath is required when arcadedb.logging.enabled is true" .Values.arcadedb.logging.mountPath) -}}
{{- $configDir := trimSuffix "/" .Values.arcadedb.configDirectory -}}
{{- if or (eq $mountPath $configDir) (hasPrefix (printf "%s/" $configDir) $mountPath) (hasPrefix (printf "%s/" $mountPath) $configDir) -}}
{{- fail (printf "arcadedb.logging.mountPath (%s) must be outside arcadedb.configDirectory (%s): mounting the logging ConfigMap on, inside or above the config directory would hide it or the config volume" .Values.arcadedb.logging.mountPath .Values.arcadedb.configDirectory) -}}
{{- end -}}
{{- $mountPath -}}
{{- end -}}

{{/*
Guard: scrape discovery (ServiceMonitor or pod annotations) needs the
prometheus plugin so /prometheus is actually served.
*/}}
{{- define "arcadedb.observability.validate" -}}
{{- $p := (((.Values.observability | default dict).metrics | default dict).prometheus) | default dict -}}
{{- $serviceMonitor := $p.serviceMonitor | default dict -}}
{{- $podAnnotations := $p.podAnnotations | default dict -}}
{{- if or $serviceMonitor.enabled $podAnnotations.enabled -}}
  {{- $promEnabled := false -}}
  {{- with (.Values.arcadedb.plugins | default dict).prometheus -}}
    {{- if .enabled -}}{{- $promEnabled = true -}}{{- end -}}
  {{- end -}}
  {{- if not $promEnabled -}}
    {{- fail "observability.metrics.prometheus serviceMonitor/podAnnotations require arcadedb.plugins.prometheus.enabled=true (the /prometheus endpoint must be served)" -}}
  {{- end -}}
{{- end -}}
{{- end -}}

{{/*
Merge user-supplied podAnnotations with the checksum/logging annotation and
computed prometheus.io/* scrape annotations. Returns YAML (possibly empty).
*/}}
{{- define "arcadedb.podAnnotations" -}}
{{- $annotations := deepCopy (default dict .Values.podAnnotations) -}}
{{- if include "arcadedb.logging.enabled" . -}}
  {{- /* JUL reads the file once at startup: roll the pods when it changes. */ -}}
  {{- $_ := set $annotations "checksum/logging" (include "arcadedb.logging.properties" . | sha256sum) -}}
{{- end -}}
{{- $pa := (((((.Values.observability | default dict).metrics | default dict).prometheus) | default dict).podAnnotations) | default dict -}}
{{- if $pa.enabled -}}
  {{- $port := int .Values.service.http.port -}}
  {{- if $pa.port -}}{{- $port = int $pa.port -}}{{- end -}}
  {{- $_ := set $annotations "prometheus.io/scrape" "true" -}}
  {{- $_ := set $annotations "prometheus.io/port" (printf "%d" $port) -}}
  {{- $_ := set $annotations "prometheus.io/path" (default "/prometheus" $pa.path) -}}
{{- end -}}
{{- if $annotations -}}
{{- toYaml $annotations -}}
{{- end -}}
{{- end -}}

{{/*
Merge the generated config-chown init container with user-supplied init containers.
config-chown is generated when initContainers.configDirectory.volumeName and mountPath are set.
It mounts that volume at the same path as the ArcadeDB container, so arcadedb.configDirectory
resolves onto the volume, then creates the directory (if missing) and always chowns it to the
ArcadeDB user. Running before the main container also stops the runtime from creating the
directory as root when it sets up the backup.json / mcp-config.json subPath mounts.
Returns YAML (possibly empty).
*/}}
{{- define "arcadedb.initContainers" -}}
{{- $cfg := .Values.initContainers.configDirectory -}}
{{- if and $cfg.volumeName $cfg.mountPath -}}
{{- $mountPath := trimSuffix "/" $cfg.mountPath -}}
{{- $configDir := trimSuffix "/" .Values.arcadedb.configDirectory -}}
{{- if not (or (eq $configDir $mountPath) (hasPrefix (printf "%s/" $mountPath) $configDir)) -}}
{{- fail (printf "initContainers.configDirectory.mountPath (%s) must be arcadedb.configDirectory (%s) or one of its parent directories: use the path the volume is mounted at in the ArcadeDB container" $cfg.mountPath .Values.arcadedb.configDirectory) -}}
{{- end -}}
{{- $uid := required "initContainers.configDirectory requires securityContext.runAsUser to know which user should own the config directory" .Values.securityContext.runAsUser -}}
{{- $gid := .Values.securityContext.runAsGroup | default (dig "fsGroup" "" (.Values.podSecurityContext | default dict)) | default $uid -}}
{{- $image := $cfg.image }}
- name: config-chown
  image: "{{ $image.registry }}/{{ $image.repository }}:{{ $image.tag }}"
  imagePullPolicy: {{ $image.pullPolicy }}
  securityContext:
    runAsUser: 0
    runAsGroup: 0
    runAsNonRoot: false
    allowPrivilegeEscalation: false
    readOnlyRootFilesystem: true
    capabilities:
      drop: [ALL]
      add: [CHOWN, DAC_OVERRIDE]
    seccompProfile:
      type: RuntimeDefault
  command:
    - sh
    - -c
    - mkdir -p "$1" && chown "$2" "$1"
    - config-chown
    - {{ $configDir | quote }}
    - {{ printf "%v:%v" $uid $gid | quote }}
  volumeMounts:
    - name: {{ $cfg.volumeName }}
      mountPath: {{ $cfg.mountPath }}
{{- end }}
{{- include "arcadedb.configSeed.container" . }}
{{- with .Values.initContainers.otherContainers }}
{{ toYaml . }}
{{- end }}
{{- end -}}

{{/*
Returns "true" when Raft HA is active (replicaCount > 1 or autoscaling), "".
Same condition the StatefulSet uses to emit the -Darcadedb.ha.* arguments.
*/}}
{{- define "arcadedb.ha.enabled" -}}
{{- if or (gt (int .Values.replicaCount) 1) .Values.autoscaling.enabled -}}true{{- end -}}
{{- end -}}

{{/*
Secret and key holding the root password: the user-supplied one, else the
chart-generated arcadedb-credentials-secret. Returns YAML {name, key}.
*/}}
{{- define "arcadedb.credentials.rootPasswordSecret" -}}
{{- $s := .Values.arcadedb.credentials.rootPassword.secret -}}
{{- if $s.name }}
name: {{ $s.name }}
key: {{ $s.key }}
{{- else }}
name: arcadedb-credentials-secret
key: rootPassword
{{- end }}
{{- end -}}

{{/*
Secret and key holding the dedicated HA cluster token. Returns YAML {name, key},
or nothing when there is none: a user-supplied root password Secret makes the
token opt-in, since that Secret may not carry a clusterToken key and a missing
key would leave the pods stuck in ContainerCreating after an upgrade.
*/}}
{{- define "arcadedb.credentials.clusterTokenSecret" -}}
{{- $c := .Values.arcadedb.credentials -}}
{{- $t := ($c.clusterToken | default dict).secret | default dict -}}
{{- if $t.name }}
name: {{ $t.name }}
key: {{ $t.key | default "clusterToken" }}
{{- else if not $c.rootPassword.secret.name }}
name: arcadedb-credentials-secret
key: clusterToken
{{- end }}
{{- end -}}

{{/*
Returns "true" when the cluster token file is mounted and passed with
-Darcadedb.ha.clusterTokenPath: HA is active and a token Secret is known.
*/}}
{{- define "arcadedb.credentials.mountClusterToken" -}}
{{- if and (include "arcadedb.ha.enabled" .) (include "arcadedb.credentials.clusterTokenSecret" . | trim) -}}true{{- end -}}
{{- end -}}

{{/*
Returns "true" when the image tag is a release at or after 26.11.1, the first
server that derives the HA cluster token from arcadedb.server.rootPasswordPath
(ArcadeData/arcadedb#10479). A tag without a leading x.y.z (latest, a digest
alias) is treated as older.
*/}}
{{- define "arcadedb.image.derivesTokenFromPasswordFile" -}}
{{- $version := regexFind "^[0-9]+\\.[0-9]+\\.[0-9]+" (include "arcadedb.image.tag" .) -}}
{{- if and $version (semverCompare ">=26.11.1" $version) -}}true{{- end -}}
{{- end -}}

{{/*
Returns "true" when the root password is passed as a mounted file
(-Darcadedb.server.rootPasswordPath) instead of on the command line, where it
is readable through /proc/<pid>/cmdline. Before 26.11.1 an HA node derives its
cluster token from the inline arcadedb.server.rootPassword only, so in HA the
file is used only when an explicit token is mounted or the image derives the
token from the file.
*/}}
{{- define "arcadedb.credentials.rootPasswordFromFile" -}}
{{- if or (not (include "arcadedb.ha.enabled" .)) (include "arcadedb.credentials.mountClusterToken" .) (include "arcadedb.image.derivesTokenFromPasswordFile" .) -}}true{{- end -}}
{{- end -}}

{{/*
Group-readable (0440) when the pod has an fsGroup, which owns the projected
files and is a supplementary group of every container process; world-readable
(0444) otherwise, since a secret volume is owned by root and the server runs
unprivileged. Decimal, because YAML 1.2 parsers read 0440 as a decimal number.
*/}}
{{- define "arcadedb.credentials.fileMode" -}}
{{- if (.Values.podSecurityContext | default dict).fsGroup -}}288{{- else -}}292{{- end -}}
{{- end -}}

{{/*
Storage plan for the reserved arcadedb-data / arcadedb-config / arcadedb-raft
volumes (#34), returned as JSON:
  claims    - volumeClaimTemplates the chart generates from persistence.*
  volumes   - the pod volumes: the `volumes` value minus the emptyDir entries a
              generated claim replaces, plus an emptyDir for every reserved name
              nothing else backs
  ephemeral - reserved names that end up on an emptyDir and hold state worth
              keeping (arcadedb-raft only counts while HA is active)

A reserved name the user backs explicitly - a `volumeClaimTemplates` entry, or a
`volumes` entry that is not an emptyDir - is left alone. An emptyDir entry in
`volumes` does not block persistence: values files copied from older charts list
every reserved name as an emptyDir, and the persistence.* flags must still win.
*/}}
{{- define "arcadedb.persistence.plan" -}}
{{- $ha := or (gt (int .Values.replicaCount) 1) .Values.autoscaling.enabled -}}
{{- $data := .Values.persistence | default dict -}}
{{- $config := $data.config | default dict -}}
{{- $raft := $data.raft | default dict -}}
{{- $reserved := list
      (dict "name" "arcadedb-data" "settings" $data "enabled" $data.enabled "stateful" true)
      (dict "name" "arcadedb-config" "settings" $config "enabled" $config.enabled "stateful" true)
      (dict "name" "arcadedb-raft" "settings" $raft "enabled" (and $ha $raft.enabled) "stateful" $ha) -}}
{{- $userClaims := dict -}}
{{- range .Values.volumeClaimTemplates -}}
{{- with .metadata -}}{{- with .name -}}{{- $_ := set $userClaims . true -}}{{- end -}}{{- end -}}
{{- end -}}
{{- $userVolumes := dict -}}
{{- range .Values.volumes -}}
{{- with .name -}}{{- $_ := set $userVolumes . true -}}{{- end -}}
{{- end -}}
{{- $userEmptyDirs := dict -}}
{{- range .Values.volumes -}}
{{- if and .name (hasKey . "emptyDir") -}}{{- $_ := set $userEmptyDirs .name true -}}{{- end -}}
{{- end -}}
{{- $claims := list -}}
{{- $generated := dict -}}
{{- $fallback := list -}}
{{- $ephemeral := list -}}
{{- range $reserved -}}
{{- $name := .name -}}
{{- $userOwned := or (hasKey $userClaims $name) (and (hasKey $userVolumes $name) (not (hasKey $userEmptyDirs $name))) -}}
{{- if $userOwned -}}
{{- else if .enabled -}}
{{- $spec := dict "accessModes" (list .settings.accessMode) "resources" (dict "requests" (dict "storage" .settings.size)) -}}
{{- with .settings.storageClass -}}{{- $_ := set $spec "storageClassName" . -}}{{- end -}}
{{- $claims = append $claims (dict "metadata" (dict "name" $name) "spec" $spec) -}}
{{- $_ := set $generated $name true -}}
{{- else -}}
{{- if not (hasKey $userVolumes $name) -}}
{{- $fallback = append $fallback (dict "name" $name "emptyDir" dict) -}}
{{- end -}}
{{- if .stateful -}}{{- $ephemeral = append $ephemeral $name -}}{{- end -}}
{{- end -}}
{{- end -}}
{{- $volumes := list -}}
{{- range .Values.volumes -}}
{{- if not (and .name (hasKey $generated .name)) -}}{{- $volumes = append $volumes . -}}{{- end -}}
{{- end -}}
{{- dict "claims" $claims "volumes" (concat $fallback $volumes) "ephemeral" $ephemeral | toJson -}}
{{- end -}}

{{/*
Config directory seeding (issue #39). The arcadedb-config volume hides every file
the image ships in installDirectory/config. Two of them change behaviour when
missing: server-groups.json (the server uses a built-in default without the
"readonly" group) and gremlin-server.yaml with its .properties / .groovy (the
Gremlin plugin starts from an empty Settings). The logging files are left out:
the chart ships arcadedb-log.properties from a ConfigMap (#38).
*/}}
{{- define "arcadedb.configSeed.files" -}}
{{- list "server-groups.json" "gremlin-server.yaml" "gremlin-server.properties" "gremlin-server.groovy" | toJson -}}
{{- end -}}

{{/*
The volumeMounts entry that holds arcadedb.configDirectory: the deepest mountPath
that is the directory or one of its parents. Returns JSON {} when none does.
*/}}
{{- define "arcadedb.configSeed.mount" -}}
{{- $configDir := trimSuffix "/" .Values.arcadedb.configDirectory -}}
{{- $found := dict -}}
{{- $depth := -1 -}}
{{- range .Values.volumeMounts -}}
{{- $mountPath := trimSuffix "/" (toString .mountPath) -}}
{{- if and .name (or (eq $configDir $mountPath) (hasPrefix (printf "%s/" $mountPath) $configDir)) (gt (len $mountPath) $depth) -}}
{{- $found = . -}}
{{- $depth = len $mountPath -}}
{{- end -}}
{{- end -}}
{{- $found | toJson -}}
{{- end -}}

{{/*
The config-seed init container. It runs the server image itself (same registry,
repository and tag, so the defaults match the server version) with the volume
that holds configDirectory mounted at /config-seed instead of over the image's
config/, and copies each file the directory does not hold yet. Existing files,
including ones the server or an operator changed, are never overwritten.
Skipped on the native image (no shell), when disabled, and when no volumeMounts
entry holds configDirectory (nothing would outlive the init container).
A values file without the key (helm upgrade --reuse-values) keeps it on.
*/}}
{{- define "arcadedb.configSeed.container" -}}
{{- $seed := (.Values.initContainers | default dict).configSeed | default dict -}}
{{- $enabled := or (not (hasKey $seed "enabled")) $seed.enabled -}}
{{- $mount := include "arcadedb.configSeed.mount" . | fromJson -}}
{{- if and $enabled $mount (not (include "arcadedb.native" .)) -}}
{{- $configDir := trimSuffix "/" .Values.arcadedb.configDirectory -}}
{{- $target := printf "/config-seed%s" (trimPrefix (trimSuffix "/" (toString $mount.mountPath)) $configDir) -}}
{{- $source := printf "%s/config" (trimSuffix "/" .Values.arcadedb.installDirectory) }}
- name: config-seed
  image: "{{ .Values.image.registry }}/{{ .Values.image.repository }}:{{ include "arcadedb.image.tag" . }}"
  imagePullPolicy: {{ .Values.image.pullPolicy }}
  {{- with .Values.securityContext }}
  securityContext:
    {{- toYaml . | nindent 4 }}
  {{- end }}
  command:
    - sh
    - -c
    - |
      set -e
      src="$1"; dst="$2"; shift 2
      mkdir -p "$dst"
      for f in "$@"; do
        if [ -e "$dst/$f" ]; then
          echo "config-seed: keeping existing $f"
        elif [ -f "$src/$f" ]; then
          cat "$src/$f" > "$dst/.$f.seed"
          mv "$dst/.$f.seed" "$dst/$f"
          echo "config-seed: seeded $f"
        else
          echo "config-seed: $f is not in the image, skipped"
        fi
      done
  args:
    - config-seed
    - {{ $source | quote }}
    - {{ $target | quote }}
    {{- range include "arcadedb.configSeed.files" . | fromJsonArray }}
    - {{ . | quote }}
    {{- end }}
  volumeMounts:
    - name: {{ $mount.name }}
      mountPath: /config-seed
      {{- with $mount.subPath }}
      subPath: {{ . }}
      {{- end }}
{{- end }}
{{- end -}}
