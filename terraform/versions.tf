terraform {
  # 1.10+ is needed for native S3 state locking (use_lockfile) in backend.tf
  required_version = ">= 1.10.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}
