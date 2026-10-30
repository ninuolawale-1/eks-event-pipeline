# Setup

## Prerequisites

* AWS account with the AWS CLI v2 configured (`aws sts get-caller-identity` works)
* Terraform 1.10+, kubectl, Helm 3, Flux CLI, GitHub CLI (`gh`)
* Docker with at least 8 GB of memory allocated
* A GitHub personal access token (classic) with `repo` scope, for `flux bootstrap`

On macOS:

```bash
brew install awscli kubectl helm gh make hashicorp/tap/terraform fluxcd/tap/flux
```

## Local

```bash
make local-up       # Kafka, Postgres, Elasticsearch, producer, consumer
make local-logs
make test
make local-down
```

* Producer metrics: http://localhost:8001/metrics
* Consumer metrics: http://localhost:8002/metrics
* Postgres: `docker compose exec postgres psql -U app -d events`

## AWS

### 1. State bucket and infrastructure

```bash
make state                                   # one time; kept between rebuilds
# create terraform/terraform.tfvars (git-ignored), for example:
#   github_owner                 = "<github-user>"
#   endpoint_public_access_cidrs = ["<your-ip>/32"]
#   node_capacity_type           = "ON_DEMAND"
#   node_min_size = 2, node_desired_size = 2, node_max_size = 2
#   github_oidc_sub_prefix       = "<from: gh api repos/OWNER/REPO/actions/oidc/customization/sub>"
make tf-init
make tf-plan
make tf-apply                                # ~15-20 minutes
```

### 2. CI

```bash
make configure                               # fills placeholders, sets GitHub repo variables
git add -A && git commit -m "Configure account" && git push
gh workflow run build-and-release && gh run watch
git pull                                     # pick up the image tag commit from CI
```

`platform/apps/overlays/dev/producer-patch.yaml` should now have a commit SHA instead of `set-by-ci`.

GitHub repository variables used by the workflows:

| Variable | Source |
|---|---|
| `AWS_REGION` | e.g. `us-east-1` |
| `AWS_ROLE_ARN` | `terraform output github_actions_role_arn` |
| `TF_PLAN_ROLE_ARN` | `terraform output github_terraform_plan_role_arn` |
| `TF_STATE_BUCKET` | `terraform -chdir=terraform/bootstrap output state_bucket` |
| `TF_ENDPOINT_CIDRS` (optional) | JSON list matching tfvars, e.g. `["203.0.113.7/32"]` |

If the tag-bump job can't push, set **Settings > Actions > General > Workflow permissions** to read and write.

### 3. Flux

```bash
export GITHUB_TOKEN=<personal access token>
./scripts/bootstrap-flux.sh <github-user>
git pull
flux get kustomizations --watch              # infra-configs, infra-controllers, pipeline
make status
```

First sync takes 10-15 minutes.

## Operating

| Task | Command |
|---|---|
| Dashboards (Grafana :3000, Prometheus :9090, Alertmanager :9093) | `make ui` |
| Load test and watch KEDA | `make load-test` and `kubectl get hpa -n pipeline -w` |
| Compare dev and prod manifests | `make render` |
| Chaos tests | `./scripts/chaos-test.sh kafka\|postgres\|consumer\|elastic` |
| Promote dev image to prod | Actions > promote-to-prod |
| Health check | `make status` |

## Teardown

```bash
make teardown
aws eks list-clusters      # should be empty
```

The S3 state bucket is kept. To rebuild, start again from `make tf-apply`.

## Troubleshooting

| Symptom | Fix |
|---|---|
| Pods in `ImagePullBackOff` | Image tag is still `set-by-ci`; rerun the build workflow and `git pull` |
| Pods `Pending` | `kubectl describe pod`; if memory, raise `node_desired_size` and re-apply |
| Flux Kustomization not Ready | `flux logs --level=error`, `flux get helmreleases -A` |
| Terraform plan workflow fails on init | Check `TF_STATE_BUCKET` and `TF_PLAN_ROLE_ARN` variables |
| Node group stuck in `CREATING`, no instances | Check EC2 vCPU quotas (`aws service-quotas get-service-quota --service-code ec2 --quota-code L-1216C47A`) |
| `not eligible for Free Tier` on launch | The AWS account is on the Free plan; upgrade it in Billing |
| CI fails with `Not authorized to perform sts:AssumeRoleWithWebIdentity` | Repo uses immutable OIDC subjects; set `github_oidc_sub_prefix` in tfvars and re-apply |

## Versions (as of October 2026)

| Component | Version |
|---|---|
| EKS Kubernetes | 1.35 |
| terraform-aws-modules/eks / vpc | ~> 21.0 / ~> 6.0 |
| Strimzi | 1.x (`kafka.strimzi.io/v1`) |
| KEDA | 2.16+ |
| ECK / Elasticsearch | 2.16-3.x / 8.18.0 |
| CloudNativePG chart | 0.23+ |
| kube-prometheus-stack | 70+ |
