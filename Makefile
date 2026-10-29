.PHONY: help local-up local-down local-logs test lint render state tf-init tf-plan tf-apply configure status ui load-test teardown

# Read once from the bootstrap stack so tf-* targets don't need it typed in
TF_STATE_BUCKET ?= $(shell terraform -chdir=terraform/bootstrap output -raw state_bucket 2>/dev/null)
AWS_REGION ?= us-east-1

help:            ## Show available targets
	@grep -E '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  %-12s %s\n", $$1, $$2}'

local-up:        ## Run the whole pipeline locally with Docker Compose
	docker compose up --build -d
	@echo "Producer metrics: :8001  Consumer metrics: :8002  Elasticsearch: :9200  Postgres: :5432"

local-down:      ## Stop the local stack and delete its data
	docker compose down -v

local-logs:      ## Tail producer and consumer logs
	docker compose logs -f producer consumer

test:            ## Run unit tests
	pytest -q apps/consumer/tests

lint:            ## Lint Python, Terraform, and the Helm chart
	ruff check apps/
	terraform fmt -check -recursive terraform
	helm lint charts/pipeline-app --set image.repository=example/app

render:          ## Show the fully rendered dev and prod manifests side by side
	kubectl kustomize platform/apps/overlays/dev  > /tmp/dev.yaml
	kubectl kustomize platform/apps/overlays/prod > /tmp/prod.yaml
	diff /tmp/dev.yaml /tmp/prod.yaml || true

state:           ## One-time: create the S3 bucket for Terraform state
	terraform -chdir=terraform/bootstrap init
	terraform -chdir=terraform/bootstrap apply

tf-init:         ## terraform init against the S3 backend
	@test -n "$(TF_STATE_BUCKET)" || (echo "Run 'make state' first" && exit 1)
	terraform -chdir=terraform init -backend-config="bucket=$(TF_STATE_BUCKET)" -backend-config="region=$(AWS_REGION)"

tf-plan:         ## terraform plan
	terraform -chdir=terraform plan

tf-apply:        ## terraform apply (creates billable AWS resources)
	terraform -chdir=terraform apply

configure:       ## Fill in placeholders and set GitHub variables from Terraform outputs
	./scripts/configure.sh

status:          ## Health check of the running platform
	./scripts/status.sh

ui:              ## Port-forward Grafana, Prometheus, Alertmanager
	./scripts/port-forward.sh

load-test:       ## Push load through the pipeline and watch KEDA scale
	./scripts/load-test.sh

teardown:        ## Destroy the cluster and everything in it (keeps the state bucket)
	./scripts/teardown.sh
