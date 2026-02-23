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
  description = "The database inside the existing Redshift Serverless namespace to run queries against."
  type        = string
  default     = "dev"
}
