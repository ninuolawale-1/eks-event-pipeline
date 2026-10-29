# GitOps Event Streaming Platform on Amazon EKS

<img width="900" src="docs/images/architecture.png" alt="Architecture diagram: a producer publishes events to Kafka on EKS; a consumer that KEDA scales on Kafka lag writes them to PostgreSQL and Elasticsearch; Flux syncs the cluster from Git, GitHub Actions builds and scans images into ECR, and Prometheus, Grafana, and Alertmanager monitor the platform"/>

## Platforms and Languages Leveraged
- Amazon Web Services (EKS, EC2, EBS, ECR, VPC, IAM, S3, EKS Pod Identity)
- Terraform (HashiCorp Configuration Language), AWS Provider 6.x, terraform-aws-modules (EKS v21, VPC v6)
- Kubernetes 1.35 (Helm, Kustomize, HPA, PodDisruptionBudgets, Pod Security Standards)
- Flux (GitOps, HelmReleases, drift detection)
- KEDA (event-driven autoscaling on Kafka lag)
- Apache Kafka via Strimzi, PostgreSQL via CloudNativePG, Elasticsearch via ECK
- Prometheus, Grafana, Alertmanager (kube-prometheus-stack)
- GitHub Actions (OIDC federation), Trivy, Checkov, kubeconform
- Python 3.12, Bash, Docker, Make, Git

## Scenario

The goal of this project was to run a stateful, multi-component platform on Kubernetes the way a platform team would: every piece defined in code, every change delivered through Git, and the system able to scale and recover without someone manually intervening. A lot of Kubernetes demos stop at a single stateless web app deployed with `kubectl apply`. They don't deal with databases that need failover, message queues that need replication, workloads that need to scale on something other than CPU, or the question of how a change actually gets from a commit to a running cluster safely.

This platform streams events through a three-broker Kafka cluster into PostgreSQL and Elasticsearch on Amazon EKS. A Python consumer scales on Kafka consumer-group lag, writes to both stores idempotently, and only commits its progress once both writes succeed. Flux keeps the cluster in sync with this repository and reverts manual changes. GitHub Actions tests, scans, and builds every change, posts Terraform plans on pull requests, and deploys to dev automatically, while prod only changes through a reviewed pull request. No long-lived AWS credentials exist anywhere in the setup.

### High-Level Build Plan

- **Provision** the VPC, EKS cluster, ECR repositories, and IAM roles in Terraform, with state stored remotely in S3.
- **Connect** GitHub Actions to AWS through OIDC, with separate least-privilege roles for pushing images and planning infrastructure.
- **Deploy** Kafka, PostgreSQL, and Elasticsearch through Kubernetes operators, all managed by Flux from Git.
- **Build** a producer and consumer in Python with at-least-once delivery, idempotent writes, and a dead-letter topic.
- **Scale** the consumer on Kafka lag with KEDA instead of CPU.
- **Observe** the platform with Prometheus metrics, a Grafana dashboard, and alert rules backed by runbooks.
- **Separate** dev and prod with Kustomize overlays and a pull-request-based promotion workflow.
- **Validate** the platform by loading it and breaking it on purpose.

---

## Steps Taken

### 1. Provisioned the Platform in Terraform

Defined a three-AZ VPC with private subnets for worker nodes, a single NAT gateway to keep costs down, and an EKS cluster running Kubernetes 1.35 with one managed node group of spot instances. Terraform state lives in an S3 bucket created by a separate bootstrap stack, with native S3 locking, so local runs and CI read the same state.

The EBS CSI driver, which every database and Kafka volume depends on, authenticates through EKS Pod Identity rather than a role attached to the nodes. That keeps storage permissions scoped to the one pod that needs them instead of every pod on the node.

```hcl
    aws-ebs-csi-driver = {
      pod_identity_association = [{
        role_arn        = aws_iam_role.ebs_csi.arn
        service_account = "ebs-csi-controller-sa"
      }]
    }
```

<!-- TODO: add a short note on anything that went wrong during the first apply and how you fixed it -->

**Deployed resources in AWS.**

<!-- TODO: screenshot of the EKS cluster, node group, and ECR repositories in the AWS console -->
<img width="900" src="docs/images/01-aws-resources.png" alt="Screenshot: AWS console showing the EKS cluster, managed node group, and ECR repositories"/>

### 2. Replaced Stored Credentials With OIDC Federation

GitHub Actions authenticates to AWS with short-lived OIDC tokens instead of access keys. There are two roles, and each trusts a different kind of workflow run. The push role only accepts tokens from the `main` branch and can only push to the two ECR repositories. The Terraform plan role only accepts tokens from pull requests and has read-only access, so a pull request can show what would change but can never change anything.

```hcl
  values = ["repo:${var.github_owner}/${var.github_repo}:ref:refs/heads/${var.github_branch}"]
```

```hcl
  values = ["repo:${var.github_owner}/${var.github_repo}:pull_request"]
```

### 3. Deployed Stateful Services Through Operators, Managed by Flux

Rather than hand-writing StatefulSets, each data service runs under an operator that handles its day-two operations: Strimzi for Kafka, CloudNativePG for PostgreSQL, and ECK for Elasticsearch. Flux installs them in dependency order. A default encrypted gp3 StorageClass comes first, then the operators and monitoring stack, then the pipeline itself, so custom resources are never applied before their CRDs exist.

Kafka runs three brokers in KRaft mode with `min.insync.replicas=2`, so the cluster keeps accepting writes with one broker down. PostgreSQL runs a primary and a streaming replica with automatic failover.

```yaml
spec:
  dependsOn:
    - name: infra-configs
    - name: infra-controllers
  path: ./platform/apps/overlays/dev
  prune: true
  wait: true
```

### 4. Built the Producer and Consumer for Failure

The producer generates synthetic traffic and keys each message by source IP, so related events always land on the same partition and stay in order. The consumer enriches each batch, writes it to PostgreSQL and Elasticsearch, and only then commits its Kafka offsets. If either sink is down, nothing is committed. The consumer retries with backoff and, if the sink stays down, exits so Kubernetes restarts it from the last committed offset.

Because that design means some messages get processed twice, both writes are idempotent. Postgres ignores conflicting event IDs, and Elasticsearch uses the event ID as the document ID. Malformed messages go to a dead-letter topic instead of blocking the stream.

```python
with_retries("postgres", lambda batch=events: self._write_postgres(batch))
with_retries("elasticsearch", lambda batch=events: self._write_elasticsearch(batch))
...
self.consumer.commit(asynchronous=False)
```

### 5. Autoscaled the Consumer on Kafka Lag With KEDA

The consumer spends most of its time waiting on network writes, so its CPU can look idle while it falls further and further behind. Scaling on CPU would miss that completely. KEDA scales it on consumer-group lag instead, targeting 200 messages of lag per replica.

The maximum is six replicas, matching the topic's six partitions, because Kafka assigns each partition to at most one consumer in a group and any extra consumers would sit idle. Scale-down is limited to one pod per minute so a brief dip in lag doesn't trigger a string of consumer-group rebalances.

```yaml
  triggers:
    - type: kafka
      metadata:
        consumerGroup: "auth-event-consumer"
        topic: "auth-events"
        lagThreshold: "200"
```

Flux's drift detection is enabled on both apps, so a manual `kubectl scale` or `kubectl set env` gets reverted to what Git says. The consumer's replica count is the one field excluded, since KEDA owns it.

### 6. Added Observability and Alerting

Both apps expose Prometheus metrics, including throughput, batch write time, sink errors, dead-letter count, and an end-to-end latency histogram measuring the time from event creation to landing in both stores. The Strimzi Kafka Exporter adds consumer-group lag. A Grafana dashboard, provisioned from a ConfigMap in Git, shows all of it alongside the current consumer replica count.

Nine alert rules cover the failures that matter most, and each one links to a runbook section that explains how to check and fix it.

```yaml
        - alert: PipelineStalled
          expr: |
            sum(rate(events_produced_total[5m])) > 0
              and sum(rate(events_consumed_total[5m])) == 0
          for: 5m
```

<!-- TODO: screenshot of the Grafana Event Pipeline dashboard -->
<img width="900" src="docs/images/02-grafana-dashboard.png" alt="Screenshot: Grafana dashboard showing throughput, consumer lag, KEDA replica count, and end-to-end latency"/>

### 7. Separated Environments and Gated Promotion

The pipeline is defined once in a Kustomize base, and dev and prod overlays layer on only what differs. Prod drops the synthetic producer, runs three Elasticsearch nodes and three PostgreSQL instances, keeps a minimum of two consumers, and retains Kafka volumes when the cluster is deleted.

Every merge to `main` runs tests, builds both images, scans them with Trivy, pushes them to ECR, and commits the new tag to the dev overlay, which Flux then rolls out. Promoting to prod is a separate workflow that copies the tested tag into the prod overlay and opens a pull request with a checklist, so prod only changes after review.

```yaml
  - patch: |-
      $patch: delete
      apiVersion: helm.toolkit.fluxcd.io/v2
      kind: HelmRelease
      metadata:
        name: producer
```

### 8. Reviewed Infrastructure Changes in Pull Requests

Any pull request that touches Terraform runs a Checkov scan and a `terraform plan` under the read-only role, then posts the plan as a comment on the PR. Infrastructure changes get reviewed the same way as application code, with the exact diff in front of the reviewer. A separate CI workflow lints the Python, runs unit tests, lints and renders the Helm chart with and without KEDA, and schema-validates every rendered manifest with kubeconform.

<!-- TODO: screenshot of a Terraform plan comment on a pull request -->
<img width="700" src="docs/images/03-terraform-plan-comment.png" alt="Screenshot: GitHub pull request with an automated Terraform plan comment"/>

### 9. Validated the Platform Under Load and Failure

Each design choice was tested by creating the situation it's meant to handle, not just by confirming the happy path works.

**Load test (`make load-test`)**

<!-- TODO: screenshot of the load-test output or the KEDA replica panel climbing -->
<img width="700" src="docs/images/04-load-test.png" alt="Screenshot: consumer replicas scaling up as Kafka lag climbs during a load test"/>

**Chaos tests (`scripts/chaos-test.sh`)**

<!-- TODO: screenshot of a Postgres failover or broker loss, with the alert that fired -->
<img width="700" src="docs/images/05-chaos-test.png" alt="Screenshot: recovery after a PostgreSQL primary failover, with the alert firing and then resolving"/>

**Pipeline run with all checks passing**

<!-- TODO: screenshot of a green GitHub Actions run -->
<img width="700" src="docs/images/06-pipeline-green.png" alt="Screenshot: GitHub Actions run with test, build, scan, and deploy jobs passing"/>

---

## Platform Controls

<!-- TODO: fill in the Validation column with your real results from docs/failure-tests.md -->

| Control | Without it | With it | Validation |
|---|---|---|---|
| Consumer scaling | Fixed replica count; falls behind under load | KEDA scales 1-6 replicas on Kafka lag | Load test: scaled to _ replicas, drained _ messages of lag in _ |
| Delivery guarantees | Offsets committed before writes; events lost on crash | Commit only after both sinks succeed; idempotent writes | Consumer killed mid-batch: _ lost, _ duplicates |
| Kafka durability | Single broker; one failure stops writes | 3 brokers, replication factor 3, min ISR 2 | Broker deleted: recovered in _ s, producer kept writing |
| Database availability | Single Postgres pod | Primary + replica with automatic failover | Primary deleted: failover in _ s |
| Configuration drift | Manual changes persist silently | Flux drift detection restores Git state | `kubectl scale` reverted in _ |
| Environment promotion | Deploy straight to prod | Dev auto-deploys; prod changes only via reviewed PR | Promotion PR opened and merged for image `_` |
| Infrastructure review | `terraform apply` unreviewed | Checkov scan and plan posted on every PR | Plan comment generated on PR #_ |
| Pipeline credentials | Stored AWS access keys | OIDC roles scoped to `main` and to pull requests | No AWS secrets in the repo or GitHub settings |
| Failure visibility | Find out from users | 9 alert rules with runbooks | `_` alert fired during the _ test |

---

## Timeline of Build Events

<!-- TODO: adjust to match the order you actually built things, and add the problems you hit along the way -->

1. **Local Pipeline Built**: Producer and consumer running end to end with Docker Compose, with unit tests for the enrichment logic.
2. **Platform Provisioned**: VPC, EKS, ECR, and IAM deployed with Terraform, with remote state in S3.
3. **OIDC Configured**: GitHub federated to AWS with no stored keys, using separate push and plan roles.
4. **GitOps Bootstrapped**: Flux installed; operators, monitoring, and the pipeline deployed from Git in dependency order.
5. **CI/CD Wired Up**: Tests, Trivy scans, image builds, and automatic dev deploys on every merge.
6. **Autoscaling Added**: KEDA scaling the consumer on Kafka lag, with tuned scale-down behavior.
7. **Alerting Added**: Prometheus rules, Grafana dashboard, and runbooks.
8. **Environments Split**: Dev and prod overlays with a PR-based promotion workflow and Terraform plans on pull requests.
9. **Platform Validated**: Load test and chaos tests run against the live cluster, with results recorded.

---

## Usage

```bash
# 1. Run locally
make local-up && make test

# 2. Provision AWS
aws configure
make state                                         # one-time S3 bucket for Terraform state
cp terraform/terraform.tfvars.example terraform/terraform.tfvars   # set github_owner and your IP
make tf-init && make tf-apply

# 3. Wire up CI (sets GitHub variables), then build the first images
make configure
git push && gh workflow run build-and-release

# 4. Install Flux and let it deploy everything
export GITHUB_TOKEN=<personal access token>
./scripts/bootstrap-flux.sh <github-owner>
make status

# 5. Operate it, prove it, then tear down
make ui                       # Grafana, Prometheus, Alertmanager
make load-test
./scripts/chaos-test.sh postgres
make teardown
```

**Requirements:** an AWS account with admin access (Terraform creates IAM roles), AWS CLI v2, Terraform 1.10+, kubectl, Helm 3, the Flux CLI, the GitHub CLI, and Docker for local runs. Full setup and troubleshooting are in [docs/setup.md](docs/setup.md). Running the cluster costs roughly $0.25-0.35 an hour on spot instances.

---

## Summary

This project runs a stateful event streaming platform on Amazon EKS where every piece, from the VPC to the image tag running in each environment, is defined in code and delivered through Git. Kafka, PostgreSQL, and Elasticsearch run under their operators with replication and failover. The consumer scales on Kafka lag rather than CPU, commits progress only after both writes succeed, and handles replays without creating duplicates. Changes flow through tested, scanned, and reviewed pipelines, credentials are short-lived throughout, and the platform's behavior under load and failure was validated by actually causing both.

---

## Lessons Learned

<!-- TODO: replace or add to these with what you actually ran into. Specific problems you hit and fixed are the most convincing part of this section. -->

- **Scale on the bottleneck, not the default metric.** A consumer waiting on I/O can be badly behind with almost no CPU usage. Lag measures what users actually feel.
- **Partition count caps your parallelism.** Consumers beyond the partition count do nothing, so autoscaling limits have to be set with the topic design in mind.
- **At-least-once delivery requires idempotent writes.** Committing offsets after the writes prevents data loss, but it guarantees some replays, so every sink has to handle seeing the same event twice.
- **Autoscaling can't fix a downstream outage.** When a sink is down, lag grows and KEDA adds consumers that all wait on the same broken dependency. Alerting has to catch that case, because scaling won't.
- **Git should be the only way to change the cluster.** Drift detection turns "someone ran a `kubectl` command" from a silent problem into something that gets corrected automatically.

---

## Next Steps

- Run stateful workloads on an on-demand node group and keep spot capacity, or Karpenter, for stateless pods.
- Turn TLS back on for Elasticsearch and switch Kafka clients to mTLS with per-application users and ACLs.
- Apply Terraform automatically on merge behind a GitHub Environment with required reviewers.
- Stand up the prod overlay on a second cluster instead of only rendering it.
- Route Alertmanager notifications to Slack and pin all GitHub Actions to full commit SHAs.