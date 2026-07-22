provider "aws" {
  region = var.aws_region

  # When null, the AWS provider uses the standard credential chain:
  # AWS_PROFILE / SSO token cache / environment variables / instance role.
  # The bootstrap script relies on `aws sso login` or a named profile, so no
  # static access keys are ever handled, prompted, or written by this project.
  profile = var.aws_profile

  default_tags {
    tags = merge(
      {
        Project     = var.project_name
        Environment = var.environment
        ManagedBy   = "terraform"
        Demo        = "ai-driven-ansible-automation"
      },
      var.extra_tags,
    )
  }
}
