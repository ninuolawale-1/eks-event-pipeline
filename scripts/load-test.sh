#!/usr/bin/env bash
# Pushes load through the pipeline and watches KEDA scale the consumer on lag.
#
#   ./scripts/load-test.sh [producer_replicas] [events_per_sec_each] [duration_sec] [consumer_delay_ms]
#   ./scripts/load-test.sh               # defaults: 4 producers x 500/s for 5 min, 500 ms per batch
#
# The consumer delay simulates heavier per-batch work so one consumer can't keep
# up and lag actually builds. Set it to 0 to test raw throughput instead.
#
# Flux is suspended for the two releases during the test and resumed on exit.
# Drift detection then puts both Deployments back to exactly what Git says.
set -euo pipefail

NS=pipeline
REPLICAS="${1:-4}"
RATE="${2:-500}"
DURATION="${3:-300}"
DELAY_MS="${4:-500}"

cleanup() {
  echo
  echo "Restoring Git state (Flux resume + drift correction)..."
  flux resume helmrelease producer -n "$NS" || true
  flux resume helmrelease consumer -n "$NS" || true
  echo "Done. Watch the consumer scale back down over the next few minutes:"
  echo "  kubectl get hpa -n $NS -w"
}
trap cleanup EXIT

echo "Load: ${REPLICAS} producers x ${RATE} events/s = $((REPLICAS * RATE)) events/s for ${DURATION}s"
echo "Consumer per-batch delay: ${DELAY_MS} ms"
echo

flux suspend helmrelease producer -n "$NS"
flux suspend helmrelease consumer -n "$NS"

kubectl set env deployment/producer -n "$NS" EVENTS_PER_SECOND="$RATE"
kubectl scale deployment/producer -n "$NS" --replicas="$REPLICAS"
kubectl set env deployment/consumer -n "$NS" PROCESSING_DELAY_MS="$DELAY_MS"

HPA="keda-hpa-consumer"
printf '%-10s %-10s %-10s %-18s\n' "elapsed" "replicas" "desired" "avg lag/replica"
END=$((SECONDS + DURATION))
START=$SECONDS
while (( SECONDS < END )); do
  CUR="$(kubectl get hpa "$HPA" -n "$NS" -o jsonpath='{.status.currentReplicas}' 2>/dev/null || echo '?')"
  DES="$(kubectl get hpa "$HPA" -n "$NS" -o jsonpath='{.status.desiredReplicas}' 2>/dev/null || echo '?')"
  LAG="$(kubectl get hpa "$HPA" -n "$NS" -o jsonpath='{.status.currentMetrics[0].external.current.averageValue}' 2>/dev/null || echo '?')"
  printf '%-10s %-10s %-10s %-18s\n' "$((SECONDS - START))s" "${CUR:-?}" "${DES:-?}" "${LAG:-?}"
  sleep 15
done

echo
echo "Load test finished. Note the peak replicas, peak lag, and drain time from Grafana."
