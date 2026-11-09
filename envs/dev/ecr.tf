# Private container registry for the app image.
# Shared by ALL environments (build once, promote the same image dev -> prod), so it is owned by
# this stack and read by envs/prod with a data source. A larger setup would give it its own
# "shared" stack.
resource "aws_ecr_repository" "app" {
  name = "${local.project}/retail-health"

  # IMMUTABLE: a tag (git SHA) always points to the same image. Prevents "someone re-pushed
  # the tag" surprises and makes rollbacks exact. No mutable `latest` tag in production.
  image_tag_mutability = "IMMUTABLE"

  image_scanning_configuration {
    scan_on_push = true # basic scan (free) on every push
  }

  encryption_configuration {
    encryption_type = "AES256"
  }

  # Lab setting: allow `terraform destroy` even if images exist. In production keep this false.
  force_delete = true

  tags = { Name = "${local.project}-retail-health" }
}

# Storage costs money ($0.10/GB-month): keep only what's useful for rollbacks.
resource "aws_ecr_lifecycle_policy" "app" {
  repository = aws_ecr_repository.app.name

  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Expire untagged images after 1 day"
        selection = {
          tagStatus   = "untagged"
          countType   = "sinceImagePushed"
          countUnit   = "days"
          countNumber = 1
        }
        action = { type = "expire" }
      },
      {
        rulePriority = 2
        description  = "Keep only the 10 most recent images"
        selection = {
          tagStatus   = "any"
          countType   = "imageCountMoreThan"
          countNumber = 10
        }
        action = { type = "expire" }
      },
    ]
  })
}
