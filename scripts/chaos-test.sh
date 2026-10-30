#!/usr/bin/env bash
# Break something on purpose and time the recovery.
#
#   ./scripts/chaos-test.sh kafka      # delete one Kafka broker pod
#   ./scripts/chaos-test.sh postgres   # delete the Postgres primary (forces failover)
#   ./scripts/chaos-test.sh consumer   # delete a consumer pod mid-stream
#   ./scripts/chaos-test.sh elastic    # delete the Elasticsearch pod (sink outage)
set -euo pipefail

NS=pipeline
TARGET="${1:?usage: chaos-test.sh kafka|postgres|consumer|elastic}"

case "$TARGET" in
  kafka)    SELECTOR="strimzi.io/cluster=events,strimzi.io/pool-name=dual-role" ;;
  postgres) SELECTOR="cnpg.io/cluster=events-db,cnpg.io/instanceRole=primary" ;;
  consumer) SELECTOR="app.kubernetes.io/name=consumer" ;;
  elastic)  SELECTOR="elasticsearch.k8s.elastic.co/cluster-name=events" ;;
  *) echo "unknown target: $TARGET"; exit 1 ;;
esac

POD="$(kubectl get pods -n "$NS" -l "$SELECTOR" -o jsonpath='{.items[0].metadata.name}')"
echo "Target pod: $POD"

if [[ "$TARGET" == "postgres" ]]; then
  echo "Primary before:"
  kubectl get clusters.postgresql.cnpg.io events-db -n "$NS" -o jsonpath='{.status.currentPrimary}{"\n"}'
fi

START=$(date +%s)
kubectl delete pod "$POD" -n "$NS" --wait=false
echo "Deleted at $(date -u +%H:%M:%SZ). Waiting for all matching pods to be Ready..."

sleep 5
if [[ "$TARGET" == "postgres" ]]; then
  # During failover no pod carries the primary label for a while, so wait on
  # the cluster's own status instead of a pod.
  until [[ "$(kubectl get clusters.postgresql.cnpg.io events-db -n "$NS" -o jsonpath='{.status.phase}')" == "Cluster in healthy state" ]]; do
    sleep 5
  done
else
  kubectl wait pods -n "$NS" -l "$SELECTOR" --for=condition=Ready --timeout=600s
fi
END=$(date +%s)

if [[ "$TARGET" == "postgres" ]]; then
  echo "Primary after:"
  kubectl get clusters.postgresql.cnpg.io events-db -n "$NS" -o jsonpath='{.status.currentPrimary}{"\n"}'
fi

echo
echo "Recovered in $((END - START)) seconds."
echo "Now check: consumer logs, Grafana lag panel, and whether any events were lost:"
echo "  kubectl logs -n $NS -l app.kubernetes.io/name=consumer --since=10m | grep -Ei 'retry|error|exiting'"
