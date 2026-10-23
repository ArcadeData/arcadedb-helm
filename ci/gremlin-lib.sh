# shellcheck shell=bash
# Helpers shared by the Gremlin port suites against a real pod:
#   ci/integration-test-gremlin.sh           writePortToConfig (#62)
#   ci/integration-test-gremlin-external.sh  portManagedExternally (#66)
# Sourced, not run. Expects RELEASE, NAMESPACE, ROLLOUT_TIMEOUT, POD and PROBE set.

cleanup() {
  kubectl delete pod -n "$NAMESPACE" "$PROBE" --ignore-not-found --wait=false >/dev/null 2>&1 || true
}

dump_pod() {
  echo "---- config-seed log ----"
  kubectl logs -n "$NAMESPACE" "$POD" -c config-seed 2>&1 || true
  echo "---- arcadedb log (tail) ----"
  kubectl logs -n "$NAMESPACE" "$POD" -c arcadedb --tail=60 2>&1 || true
}

# Retries a command for up to <seconds>: the plugin binds its port shortly after
# the pod turns Ready on HTTP, and a Service's endpoints follow a moment later.
retry() {   # retry <seconds> <cmd...>
  local deadline=$(( SECONDS + $1 )); shift
  until "$@" >/dev/null 2>&1; do
    (( SECONDS < deadline )) || return 1
    sleep 2
  done
}

listening() {   # listening <port>: the server pod has a listening TCP socket on it
  kubectl exec -n "$NAMESPACE" "$POD" -c arcadedb -- \
    sh -c "netstat -ltn | awk '{print \$4}' | grep -Eq '[:.]$1\$'"
}

service_connect() {   # service_connect <port>: TCP connect from the probe pod via the Service
  kubectl exec -n "$NAMESPACE" "$PROBE" -- nc -z -w 5 "$RELEASE" "$1"
}

# start_probe: a pod to connect from. It runs the config-seed image: it is on the
# node already, it has nc, and it is the JVM image on either flavor.
start_probe() {
  local image
  image=$(kubectl get statefulset -n "$NAMESPACE" "$RELEASE" -o json | jq -r \
    '.spec.template.spec.initContainers[]? | select(.name=="config-seed") | .image')
  [[ -n "$image" ]] || { echo "ERROR: the StatefulSet has no config-seed init container"; exit 1; }
  # A probe left by an earlier run may still be terminating: wait it out.
  kubectl delete pod -n "$NAMESPACE" "$PROBE" --ignore-not-found --wait=true >/dev/null
  kubectl run -n "$NAMESPACE" "$PROBE" --image="$image" --restart=Never \
    --image-pull-policy=IfNotPresent --command -- sleep 1800 >/dev/null
  kubectl wait -n "$NAMESPACE" --for=condition=Ready "pod/${PROBE}" --timeout="${ROLLOUT_TIMEOUT}s" >/dev/null
}

# assert_listening <port> [<port-that-must-be-closed>]: the plugin binds <port>,
# and not the other one.
assert_listening() {
  local port=$1 old=${2:-}
  retry 60 listening "$port" || {
    echo "ERROR: nothing listens on ${port} in ${POD}"
    kubectl exec -n "$NAMESPACE" "$POD" -c arcadedb -- netstat -ltn || true
    dump_pod; exit 1
  }
  if [[ -n "$old" ]] && listening "$old" 2>/dev/null; then
    echo "ERROR: ${POD} listens on Gremlin port ${old} as well"
    kubectl exec -n "$NAMESPACE" "$POD" -c arcadedb -- netstat -ltn || true
    exit 1
  fi
  echo "    Listening on ${port}${old:+, not on ${old}}."
}

assert_service_connect() {   # assert_service_connect <port>
  retry 60 service_connect "$1" || {
    echo "ERROR: ${PROBE} cannot connect to ${RELEASE}:$1"
    kubectl get svc,endpoints -n "$NAMESPACE" "$RELEASE" -o wide || true
    exit 1
  }
  echo "    Connected."
}

assert_plugin_started() {
  local log
  # Logs are read into a variable first: under pipefail, grep -q closing the pipe
  # early can fail kubectl with SIGPIPE on a long log.
  log=$(kubectl logs -n "$NAMESPACE" "$POD" -c arcadedb)
  grep -qF 'GremlinServerPlugin plugin started' <<<"$log" || {
    echo "ERROR: the server log has no 'GremlinServerPlugin plugin started'"
    dump_pod; exit 1
  }
}

# restart_pod: deletes the pod and waits for the StatefulSet to bring a new one up.
restart_pod() {
  local old_uid
  old_uid=$(kubectl get pod -n "$NAMESPACE" "$POD" -o jsonpath='{.metadata.uid}')
  kubectl delete pod -n "$NAMESPACE" "$POD" --wait=true >/dev/null
  wait_replaced "$old_uid"
}

# wait_replaced <old-uid>: waits until pod 0 is a new pod and the rollout is done.
wait_replaced() {
  local old_uid=$1 new_uid deadline=$(( SECONDS + ROLLOUT_TIMEOUT ))
  until new_uid=$(kubectl get pod -n "$NAMESPACE" "$POD" -o jsonpath='{.metadata.uid}' 2>/dev/null) \
        && [[ -n "$new_uid" && "$new_uid" != "$old_uid" ]]; do
    (( SECONDS < deadline )) || { echo "ERROR: ${POD} was not replaced (uid ${old_uid})"; exit 1; }
    sleep 2
  done
  kubectl rollout status statefulset/"$RELEASE" -n "$NAMESPACE" --timeout="${ROLLOUT_TIMEOUT}s"
  kubectl wait -n "$NAMESPACE" --for=condition=Ready "pod/${POD}" --timeout="${ROLLOUT_TIMEOUT}s" >/dev/null
  echo "    ${POD} replaced."
}
