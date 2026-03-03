variable "aws_region" {
  description = "AWS region to deploy all resources into."
  type        = string
  default     = "us-east-1"
}

variable "project_name" {
  description = "A short name used as a prefix on all resource names (S3 bucket, IAM role, Glue job)."
  type        = string
  default     = "aws-learning"
}

variable "redshift_database_name" {
  description = "The name of the database Terraform will create inside the Redshift Serverless namespace."
  type        = string
  default     = "dev"
}

variable "redshift_admin_password" {
  description = "Admin password for the Redshift Serverless namespace. Must be 8-64 chars, contain uppercase, lowercase, and a digit."
  type        = string
  sensitive   = true
  # Do NOT set a default here — supply via terraform.tfvars or the -var flag.
}
