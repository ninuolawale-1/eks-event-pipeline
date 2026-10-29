variable "aws_region" {
  description = "AWS region for every resource in this stack."
  type        = string
  default     = "us-east-1"
}

variable "project_name" {
  description = "Prefix used for the cluster, VPC, ECR repos, and IAM roles."
  type        = string
  default     = "event-pipeline"
}

variable "kubernetes_version" {
  description = "EKS Kubernetes version. Pick one in STANDARD support; versions in extended support bill the control plane at roughly 6x."
  type        = string
  default     = "1.35"
}

variable "vpc_cidr" {
  description = "CIDR block for the VPC."
  type        = string
  default     = "10.0.0.0/16"
}

variable "endpoint_public_access_cidrs" {
  description = "CIDRs allowed to reach the public EKS API endpoint. Set this to your own IP (x.x.x.x/32) instead of the whole internet."
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "node_instance_types" {
  description = "Instance types for the managed node group. Listing several improves spot availability."
  type        = list(string)
  default     = ["t3.large", "t3a.large", "m5.large", "m5a.large"]
}

variable "node_capacity_type" {
  description = "SPOT is much cheaper for a lab; ON_DEMAND avoids surprise node reclaims."
  type        = string
  default     = "SPOT"

  validation {
    condition     = contains(["SPOT", "ON_DEMAND"], var.node_capacity_type)
    error_message = "node_capacity_type must be SPOT or ON_DEMAND."
  }
}

variable "node_min_size" {
  type    = number
  default = 3
}

variable "node_desired_size" {
  type    = number
  default = 3
}

variable "node_max_size" {
  type    = number
  default = 4
}

variable "github_owner" {
  description = "GitHub user or org that owns the repo (used to scope the CI role)."
  type        = string
}

variable "github_repo" {
  description = "GitHub repository name."
  type        = string
  default     = "eks-event-pipeline"
}

variable "github_branch" {
  description = "Only workflows running on this branch can assume the CI role."
  type        = string
  default     = "main"
}

variable "create_github_oidc_provider" {
  description = "Set to false if your AWS account already has the token.actions.githubusercontent.com OIDC provider."
  type        = bool
  default     = true
}
