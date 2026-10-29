locals {
  app_images = toset(["producer", "consumer"])
}

resource "aws_ecr_repository" "app" {
  for_each = local.app_images

  name = "${var.project_name}/${each.key}"

  # Tags are commit SHAs, so they should never be overwritten
  image_tag_mutability = "IMMUTABLE"

  # Lets `terraform destroy` remove repos that still hold images
  force_delete = true

  image_scanning_configuration {
    scan_on_push = true
  }

  encryption_configuration {
    encryption_type = "AES256"
  }
}

resource "aws_ecr_lifecycle_policy" "app" {
  for_each   = aws_ecr_repository.app
  repository = each.value.name

  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Keep only the 15 most recent images"
      selection = {
        tagStatus   = "any"
        countType   = "imageCountMoreThan"
        countNumber = 15
      }
      action = { type = "expire" }
    }]
  })
}
