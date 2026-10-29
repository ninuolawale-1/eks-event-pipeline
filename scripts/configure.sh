#!/usr/bin/env bash
# Fills in the __AWS_ACCOUNT_ID__ / __AWS_REGION__ / __GITHUB_OWNER__
# placeholders using Terraform outputs, then sets the GitHub repository
# variables the workflows need. Run once after `terraform apply`.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

ACCOUNT_ID="$(terraform -chdir="$ROOT/terraform" output -raw aws_account_id)"
REGION="$(terraform -chdir="$ROOT/terraform" output -raw aws_region)"
OWNER="$(terraform -chdir="$ROOT/terraform" output -raw github_owner)"
PUSH_ROLE="$(terraform -chdir="$ROOT/terraform" output -raw github_actions_role_arn)"
PLAN_ROLE="$(terraform -chdir="$ROOT/terraform" output -raw github_terraform_plan_role_arn)"
STATE_BUCKET="$(terraform -chdir="$ROOT/terraform/bootstrap" output -raw state_bucket 2>/dev/null || echo '')"

cd "$ROOT"
for file in platform/apps/base/producer.yaml platform/apps/base/consumer.yaml platform/apps/base/alerts.yaml; do
  sed -i.bak \
    -e "s/__AWS_ACCOUNT_ID__/${ACCOUNT_ID}/g" \
    -e "s/__AWS_REGION__/${REGION}/g" \
    -e "s/__GITHUB_OWNER__/${OWNER}/g" \
    "$file"
  rm -f "${file}.bak"
done
echo "Filled in account ${ACCOUNT_ID}, region ${REGION}, owner ${OWNER}."
echo

if command -v gh >/dev/null 2>&1; then
  echo "Setting GitHub repository variables..."
  gh variable set AWS_REGION       --body "$REGION"
  gh variable set AWS_ROLE_ARN     --body "$PUSH_ROLE"
  gh variable set TF_PLAN_ROLE_ARN --body "$PLAN_ROLE"
  [[ -n "$STATE_BUCKET" ]] && gh variable set TF_STATE_BUCKET --body "$STATE_BUCKET"
  echo "Done."
else
  echo "GitHub CLI not found. Add these repository variables by hand"
  echo "(Settings > Secrets and variables > Actions > Variables):"
  echo "  AWS_REGION       = ${REGION}"
  echo "  AWS_ROLE_ARN     = ${PUSH_ROLE}"
  echo "  TF_PLAN_ROLE_ARN = ${PLAN_ROLE}"
  echo "  TF_STATE_BUCKET  = ${STATE_BUCKET:-<output state_bucket from terraform/bootstrap>}"
fi
