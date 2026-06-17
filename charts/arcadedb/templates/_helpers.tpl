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
 Creates kubernetes naming suffix.
*/}}
{{- define "arcadedb.k8sSuffix" -}}
{{- $fullname := (include "arcadedb.fullname" .) -}}
{{- printf ".%s.%s.svc.cluster.local" $fullname .Release.Namespace -}}
{{- end }}

{{/*
Create a comma-separated list of StatefulSet pod FQDNs for the Raft HA server list.
When HPA is enabled, the list is sized to autoscaling.maxReplicas so that
KubernetesAutoJoin can resolve any pod ordinal up to the maximum scale.
*/}}
{{- define "arcadedb.nodenames" -}}
{{- $replicas := int .Values.replicaCount -}}
{{- if and .Values.autoscaling.enabled (gt (int .Values.autoscaling.maxReplicas) $replicas) -}}
  {{- $replicas = int .Values.autoscaling.maxReplicas -}}
{{- end -}}
{{- $names := list -}}
{{- $fullname := (include "arcadedb.fullname" .) -}}
{{- $k8sSuffix := (include "arcadedb.k8sSuffix" .) -}}
{{- $rpcPort := int .Values.service.rpc.port -}}
{{- range $i, $_ := until $replicas }}
{{- $names = append $names (printf "%s-%d%s:%d" $fullname $i $k8sSuffix $rpcPort) }}
{{- end }}
{{- join "," $names -}}
{{- end }}

{{/*
Preparing a list of plugin ports to build plugin configurations.
*/}}
{{- define "_arcadedb.plugin.ports" -}}
  {{- range $plugin, $config := .Values.arcadedb.plugins -}}
    {{- if $config.enabled }}
      {{- $port := int 0}}
      {{- if eq $plugin "gremlin" }}
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
        {{- if not $config.port }}
          {{- fail (printf "Custom plugin '%s' has no port specified." $plugin) -}}
        {{- end }}
        {{- $port = $config.port }}
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
    {{- if eq $plugin "gremlin" -}}
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
Observability -D JVM args (logging, OTLP metrics, tracing, readiness).
All opt-in; emits nothing when defaults are unchanged.
*/}}
{{- define "arcadedb.observability.args" -}}
{{- $o := .Values.observability -}}
{{- if eq $o.logging.format "json" }}
- -Darcadedb.server.logFormat=json
{{- end }}
{{- if $o.logging.includeTrace }}
- -Darcadedb.server.logIncludeTrace=true
{{- end }}
{{- if $o.metrics.otlp.enabled }}
- -Darcadedb.serverMetrics.otlp.enabled=true
- -Darcadedb.serverMetrics.otlp.endpoint={{ $o.metrics.otlp.endpoint }}
{{- end }}
{{- if $o.tracing.enabled }}
- -Darcadedb.serverMetrics.tracing.enabled=true
- -Darcadedb.serverMetrics.tracing.endpoint={{ $o.tracing.endpoint }}
- -Darcadedb.serverMetrics.tracing.samplingRate={{ $o.tracing.samplingRate }}
{{- end }}
{{- if $o.health.readinessRequiresHA }}
- -Darcadedb.server.readinessRequiresHA=true
{{- end }}
{{- end -}}

{{/*
Guard: scrape discovery (ServiceMonitor or pod annotations) needs the
prometheus plugin so /prometheus is actually served.
*/}}
{{- define "arcadedb.observability.validate" -}}
{{- $p := .Values.observability.metrics.prometheus -}}
{{- if or $p.serviceMonitor.enabled $p.podAnnotations.enabled -}}
  {{- $promEnabled := false -}}
  {{- with .Values.arcadedb.plugins.prometheus -}}
    {{- if .enabled -}}{{- $promEnabled = true -}}{{- end -}}
  {{- end -}}
  {{- if not $promEnabled -}}
    {{- fail "observability.metrics.prometheus serviceMonitor/podAnnotations require arcadedb.plugins.prometheus.enabled=true (the /prometheus endpoint must be served)" -}}
  {{- end -}}
{{- end -}}
{{- end -}}

{{/*
Merge user-supplied podAnnotations with computed prometheus.io/* scrape
annotations. Returns YAML (possibly empty).
*/}}
{{- define "arcadedb.podAnnotations" -}}
{{- $annotations := deepCopy (default dict .Values.podAnnotations) -}}
{{- $pa := .Values.observability.metrics.prometheus.podAnnotations -}}
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
