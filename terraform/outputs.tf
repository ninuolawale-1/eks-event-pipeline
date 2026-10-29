output "aws_account_id" {
  value = data.aws_caller_identity.current.account_id
}

output "aws_region" {
  value = var.aws_region
}

output "cluster_name" {
  value = module.eks.cluster_name
}

output "update_kubeconfig_command" {
  description = "Run this to point kubectl at the new cluster."
  value       = "aws eks update-kubeconfig --region ${var.aws_region} --name ${module.eks.cluster_name}"
}

output "ecr_repository_urls" {
  value = { for k, repo in aws_ecr_repository.app : k => repo.repository_url }
}

output "github_actions_role_arn" {
  description = "Save this as the AWS_ROLE_ARN repository variable in GitHub."
  value       = aws_iam_role.github_actions.arn
}

output "github_terraform_plan_role_arn" {
  description = "Save this as the TF_PLAN_ROLE_ARN repository variable in GitHub."
  value       = aws_iam_role.github_terraform_plan.arn
}

output "github_owner" {
  value = var.github_owner
}
