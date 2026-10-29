# Remote state in S3 (created by terraform/bootstrap). Remote state is what
# lets GitHub Actions run `terraform plan` against the same state you apply from.
#
# The bucket and region are passed at init time so nothing account-specific
# is hard-coded here:
#
#   terraform init \
#     -backend-config="bucket=<state_bucket output from bootstrap>" \
#     -backend-config="region=us-east-1"
#
# use_lockfile gives state locking through S3 itself; no DynamoDB table needed.

terraform {
  backend "s3" {
    key          = "eks-event-pipeline/terraform.tfstate"
    encrypt      = true
    use_lockfile = true
  }
}
