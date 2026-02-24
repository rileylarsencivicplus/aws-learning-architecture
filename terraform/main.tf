terraform {
  required_version = ">= 1.14.5"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.100.0" # 5.84+ required for Glue 5.0 / python_version "3.11" support
    }
    random = {
      source  = "hashicorp/random"
      version = ">= 3.8.1"
    }
  }

  # State is stored locally in this directory.
  # To share state with a team, replace this with an S3 backend.
  backend "local" {}
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project   = var.project_name
      ManagedBy = "Terraform"
    }
  }
}
