#!/usr/bin/env bash
# One-shot health check of the whole platform.
set -uo pipefail

section() { printf '\n==== %s ====\n' "$1"; }

section "Flux"
flux get kustomizations
flux get helmreleases -A

section "Nodes"
kubectl get nodes -o wide

section "Kafka"
kubectl get kafka,kafkanodepool,kafkatopic -n pipeline

section "PostgreSQL"
kubectl get clusters.postgresql.cnpg.io -n pipeline

section "Elasticsearch"
kubectl get elasticsearch -n pipeline

section "Autoscaling (KEDA)"
kubectl get scaledobject,hpa -n pipeline

section "Firing alerts"
kubectl exec -n monitoring statefulset/alertmanager-kube-prometheus-stack-alertmanager -c alertmanager -- \
  amtool alert query --alertmanager.url=http://localhost:9093 2>/dev/null || echo "(Alertmanager not reachable yet)"

section "Pipeline pods"
kubectl get pods -n pipeline -o wide

section "Row count in Postgres"
PRIMARY="$(kubectl get pod -n pipeline -l cnpg.io/cluster=events-db,cnpg.io/instanceRole=primary -o name | head -n1)"
if [[ -n "$PRIMARY" ]]; then
  kubectl exec -n pipeline "$PRIMARY" -c postgres -- \
    psql -U postgres -d events -tAc \
    "SELECT count(*) AS total, count(*) FILTER (WHERE suspicious) AS suspicious FROM auth_events;"
fi
