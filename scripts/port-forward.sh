#!/usr/bin/env bash
# Opens local tunnels to the observability stack and prints the logins.
# Ctrl+C stops all tunnels.
set -euo pipefail

GRAFANA_PASS="$(kubectl get secret kube-prometheus-stack-grafana -n monitoring -o jsonpath='{.data.admin-password}' | base64 -d)"
ES_PASS="$(kubectl get secret events-es-elastic-user -n pipeline -o jsonpath='{.data.elastic}' | base64 -d)"

cat <<EOF
Grafana       http://localhost:3000   user: admin    password: ${GRAFANA_PASS}
              Dashboards > Event Pipeline
Prometheus    http://localhost:9090   Alerts tab shows rule state
Alertmanager  http://localhost:9093   currently firing alerts
Elasticsearch http://localhost:9200   user: elastic  password: ${ES_PASS}
EOF

trap 'kill $(jobs -p) 2>/dev/null' EXIT

if kubectl get svc trino -n pipeline >/dev/null 2>&1; then
  echo "Trino         http://localhost:8080   (CLI: trino --server localhost:8080)"
  kubectl port-forward -n pipeline svc/trino 8080:8080 >/dev/null &
fi

kubectl port-forward -n monitoring svc/kube-prometheus-stack-grafana 3000:80 >/dev/null &
kubectl port-forward -n monitoring svc/kube-prometheus-stack-prometheus 9090:9090 >/dev/null &
kubectl port-forward -n monitoring svc/kube-prometheus-stack-alertmanager 9093:9093 >/dev/null &
kubectl port-forward -n pipeline svc/events-es-http 9200:9200 >/dev/null &
wait
