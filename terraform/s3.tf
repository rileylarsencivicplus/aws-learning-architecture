# ─────────────────────────────────────────────
# Random suffix to guarantee a globally unique bucket name
# ─────────────────────────────────────────────
resource "random_id" "bucket_suffix" {
  byte_length = 4
}

# ─────────────────────────────────────────────
# S3 Bucket — stores the Glue Python scripts
# ─────────────────────────────────────────────
resource "aws_s3_bucket" "glue_assets" {
  bucket = "${var.project_name}-glue-assets-${random_id.bucket_suffix.hex}"

  tags = {
    Name = "${var.project_name}-glue-assets"
  }
}

# Block all public access — scripts should never be publicly readable
resource "aws_s3_bucket_public_access_block" "glue_assets" {
  bucket = aws_s3_bucket.glue_assets.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Enable versioning — keeps a history of script uploads
resource "aws_s3_bucket_versioning" "glue_assets" {
  bucket = aws_s3_bucket.glue_assets.id

  versioning_configuration {
    status = "Enabled"
  }
}

# Server-side encryption with AWS-managed keys (free, no configuration required)
resource "aws_s3_bucket_server_side_encryption_configuration" "glue_assets" {
  bucket = aws_s3_bucket.glue_assets.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# ─────────────────────────────────────────────
# Upload the Glue script to S3
# Terraform reads the local file and pushes it to scripts/glue_job_script.py
# inside the bucket. Glue will read it from here at runtime.
# ─────────────────────────────────────────────
resource "aws_s3_object" "glue_script" {
  bucket = aws_s3_bucket.glue_assets.id
  key    = "scripts/glue_job_script.py"

  # Path to the script relative to the terraform/ directory
  source = "${path.module}/../glue_job_script.py"

  # Recalculate the upload whenever the file content changes
  etag = filemd5("${path.module}/../glue_job_script.py")
}
