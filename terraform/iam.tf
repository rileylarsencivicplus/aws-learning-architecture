# ─────────────────────────────────────────────
# IAM Role for the Glue Job
#
# Think of this as a "badge" that the Glue job wears.
# The trust policy says: only AWS Glue can assume this role.
# ─────────────────────────────────────────────
resource "aws_iam_role" "glue_job_role" {
  name = "${var.project_name}-glue-job-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect    = "Allow"
        Principal = { Service = "glue.amazonaws.com" }
        Action    = "sts:AssumeRole"
      }
    ]
  })
}

# ─────────────────────────────────────────────
# AWS Managed Policy: AWSGlueServiceRole
# Gives Glue the basic permissions it needs to start up:
# reading/writing logs, accessing CloudWatch, etc.
# Does NOT cover Redshift — see the inline policy below.
# ─────────────────────────────────────────────
resource "aws_iam_role_policy_attachment" "glue_service_role" {
  role       = aws_iam_role.glue_job_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSGlueServiceRole"
}

# ─────────────────────────────────────────────
# Inline Policy: Redshift + S3 access
#
# This is the custom permissions list that fixes the
# "redshift-data:ExecuteStatement is not authorized" error.
# It grants exactly what the Glue job needs — nothing more.
# ─────────────────────────────────────────────
resource "aws_iam_role_policy" "glue_redshift_s3_policy" {
  name = "GlueRedshiftAndS3Access"
  role = aws_iam_role.glue_job_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      # Allow Glue to read the Python script from S3
      {
        Sid    = "S3ReadScript"
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:ListBucket"
        ]
        Resource = [
          aws_s3_bucket.glue_assets.arn,
          "${aws_s3_bucket.glue_assets.arn}/*"
        ]
      },
      # Allow Glue to run SQL and check status via the Redshift Data API
      {
        Sid    = "RedshiftDataAPI"
        Effect = "Allow"
        Action = [
          "redshift-data:ExecuteStatement",
          "redshift-data:DescribeStatement",
          "redshift-data:GetStatementResult",
          "redshift-data:ListStatements"
        ]
        Resource = "*"
      },
      # Allow Glue to get temporary credentials for the existing Redshift workgroup
      {
        Sid    = "RedshiftServerlessCredentials"
        Effect = "Allow"
        Action = [
          "redshift-serverless:GetCredentials",
          "redshift-serverless:GetWorkgroup"
        ]
        Resource = aws_redshiftserverless_workgroup.main.arn
      }
    ]
  })
}
