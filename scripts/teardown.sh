#!/usr/bin/env bash
# Tears everything down in the right order so nothing is left billing you.
#
# Deleting the cluster directly can orphan EBS volumes (from PVCs) and load
# balancers. So: stop Flux, delete workloads and their volumes, then destroy.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

read -r -p "This destroys the EKS cluster, VPC, and ECR repos (the Terraform state bucket is kept). Type 'destroy' to continue: " CONFIRM
[[ "$CONFIRM" == "destroy" ]] || { echo "Aborted."; exit 1; }

if kubectl cluster-info >/dev/null 2>&1; then
  echo "Suspending Flux so it doesn't recreate anything..."
  flux suspend kustomization --all || true

  echo "Deleting the pipeline namespace (releases Kafka, Postgres, and Elasticsearch volumes)..."
  kubectl delete namespace pipeline --wait=true --timeout=10m || true

  echo "Deleting any remaining PVCs and LoadBalancer services..."
  kubectl delete pvc --all -A --wait=true --timeout=5m || true
  kubectl get svc -A -o jsonpath='{range .items[?(@.spec.type=="LoadBalancer")]}{.metadata.namespace}{" "}{.metadata.name}{"\n"}{end}' \
    | while read -r ns name; do [[ -n "$ns" ]] && kubectl delete svc "$name" -n "$ns"; done

  echo "Uninstalling Flux..."
  flux uninstall --silent || true
else
  echo "Cluster not reachable; skipping in-cluster cleanup."
fi

echo "Running terraform destroy..."
cd "$ROOT/terraform"
terraform destroy -auto-approve

echo
echo "Done. Double-check for leftovers:"
echo "  aws ec2 describe-volumes --filters Name=status,Values=available --query 'Volumes[].VolumeId'"
