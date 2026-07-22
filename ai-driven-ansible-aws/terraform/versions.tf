terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.60"
    }
  }

  # ---------------------------------------------------------------------------
  # Remote state (recommended for anything beyond a single-operator demo).
  #
  # State for THIS project contains NO credentials by design: only the public
  # SSH key and non-sensitive resource metadata. Even so, enabling encrypted,
  # locked remote state is best practice. Uncomment and set your own bucket /
  # lock table, then re-run `terraform init -migrate-state`.
  # ---------------------------------------------------------------------------
  # backend "s3" {
  #   bucket         = "my-tfstate-bucket"
  #   key            = "aiops-ansible/terraform.tfstate"
  #   region         = "us-east-1"
  #   dynamodb_table = "my-tf-locks"
  #   encrypt        = true
  # }
}
