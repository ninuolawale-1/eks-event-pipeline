#!/usr/bin/env bash
# Points kubectl at the cluster and installs Flux, wired to this GitHub repo.
#
# Needs a GitHub personal access token with repo scope:
#   export GITHUB_TOKEN=ghp_...
#   ./scripts/bootstrap-flux.sh <github-owner> [repo-name]
set -euo pipefail

OWNER="${1:?usage: bootstrap-flux.sh <github-owner> [repo-name]}"
REPO="${2:-eks-event-pipeline}"
: "${GITHUB_TOKEN:?export GITHUB_TOKEN first}"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT/terraform"
REGION="$(terraform output -raw aws_region)"
CLUSTER="$(terraform output -raw cluster_name)"

aws eks update-kubeconfig --region "$REGION" --name "$CLUSTER"
kubectl get nodes

flux check --pre

flux bootstrap github \
  --owner="$OWNER" \
  --repository="$REPO" \
  --branch=main \
  --path=clusters/dev \
  --personal

echo
echo "Flux installed. Watch it reconcile with:"
echo "  flux get kustomizations --watch"
