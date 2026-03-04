# ─────────────────────────────────────────────
# S3 Bucket — MWAA DAGs
#
# MWAA requires its own dedicated S3 bucket for DAG files.
# It cannot share the existing Glue assets bucket.
# Versioning is mandatory for MWAA to detect DAG changes.
# ─────────────────────────────────────────────

resource "aws_s3_bucket" "mwaa_dags" {
  # Reuse the same random suffix as the Glue bucket so names stay consistent
  bucket = "${var.project_name}-mwaa-dags-${random_id.bucket_suffix.hex}"

  tags = {
    Name = "${var.project_name}-mwaa-dags"
  }
}

resource "aws_s3_bucket_public_access_block" "mwaa_dags" {
  bucket = aws_s3_bucket.mwaa_dags.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Required by MWAA — it uses object versions to detect when DAGs change
resource "aws_s3_bucket_versioning" "mwaa_dags" {
  bucket = aws_s3_bucket.mwaa_dags.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "mwaa_dags" {
  bucket = aws_s3_bucket.mwaa_dags.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# ─────────────────────────────────────────────
# Upload the DAG file to the S3 bucket
#
# MWAA watches the dags/ prefix in this bucket.
# Terraform re-uploads the file whenever its content changes (etag check).
# ─────────────────────────────────────────────

resource "aws_s3_object" "mwaa_dag" {
  bucket = aws_s3_bucket.mwaa_dags.id
  key    = "dags/music_stream_dag.py"
  source = "${path.module}/../dags/music_stream_dag.py"
  etag   = filemd5("${path.module}/../dags/music_stream_dag.py")

  depends_on = [aws_s3_bucket_versioning.mwaa_dags]
}

# ─────────────────────────────────────────────
# Security Group — MWAA environment
#
# MWAA requires:
#   1. A self-referential rule so Airflow components can talk to each other
#   2. Outbound HTTPS (443) so MWAA can reach AWS APIs and PyPI
# ─────────────────────────────────────────────

resource "aws_security_group" "mwaa" {
  name        = "${var.project_name}-mwaa-sg"
  description = "Security group for MWAA environment"
  vpc_id      = aws_vpc.main.id

  # Self-referential: all traffic between MWAA components (scheduler, workers, webserver)
  ingress {
    description = "Allow all traffic within the MWAA security group"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    self        = true
  }

  # Outbound HTTPS — reaches AWS APIs and downloads Python packages
  egress {
    description = "Allow all outbound traffic"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.project_name}-mwaa-sg"
  }
}

# ─────────────────────────────────────────────
# MWAA Environment
#
# mw1.small: cheapest option (~$0.49/hr) — suitable for learning.
# Run `terraform destroy` after each session to avoid ongoing charges.
# ─────────────────────────────────────────────

resource "aws_mwaa_environment" "main" {
  name              = "${var.project_name}-airflow"
  airflow_version   = "2.10.3"
  environment_class = "mw1.small"

  # IAM role that grants MWAA permissions (defined in iam.tf)
  execution_role_arn = aws_iam_role.mwaa_execution_role.arn

  # S3 location of the DAGs
  source_bucket_arn = aws_s3_bucket.mwaa_dags.arn
  dag_s3_path       = "dags/"

  # VPC networking — 2 private subnets required
  network_configuration {
    security_group_ids = [aws_security_group.mwaa.id]
    subnet_ids         = aws_subnet.private[*].id
  }

  # Enable CloudWatch logging for all Airflow components
  # Useful for debugging DAG runs without SSH access
  logging_configuration {
    dag_processing_logs {
      enabled   = true
      log_level = "INFO"
    }
    scheduler_logs {
      enabled   = true
      log_level = "INFO"
    }
    task_logs {
      enabled   = true
      log_level = "INFO"
    }
    webserver_logs {
      enabled   = true
      log_level = "INFO"
    }
    worker_logs {
      enabled   = true
      log_level = "INFO"
    }
  }

  tags = {
    Name = "${var.project_name}-airflow"
  }

  depends_on = [
    aws_s3_object.mwaa_dag,
    aws_iam_role_policy.mwaa_execution_policy,
    aws_nat_gateway.main,
  ]
}
