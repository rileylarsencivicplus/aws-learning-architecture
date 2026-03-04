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

# ─────────────────────────────────────────────
# IAM Role — MWAA Execution Role
#
# This role is assumed by the MWAA environment itself.
# The trust policy allows both airflow service principals
# (one for the environment, one for individual DAG tasks).
# ─────────────────────────────────────────────

resource "aws_iam_role" "mwaa_execution_role" {
  name = "${var.project_name}-mwaa-execution-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = [
            "airflow.amazonaws.com",
            "airflow-env.amazonaws.com"
          ]
        }
        Action = "sts:AssumeRole"
      }
    ]
  })
}

# ─────────────────────────────────────────────
# Inline Policy — MWAA Permissions
#
# Grants the MWAA role exactly what it needs:
#   - S3: read DAGs and write logs to the MWAA bucket
#   - Glue: start and monitor the music-stream-insert job
#   - CloudWatch Logs: publish task and scheduler logs
#   - MWAA: publish environment metrics
# ─────────────────────────────────────────────

resource "aws_iam_role_policy" "mwaa_execution_policy" {
  name = "MWAAExecutionPolicy"
  role = aws_iam_role.mwaa_execution_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      # MWAA reads DAG files and writes logs to its dedicated S3 bucket
      {
        Sid    = "MWAABucketAccess"
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:GetObjectVersion",
          "s3:PutObject",
          "s3:ListBucket",
          "s3:GetBucketLocation",
          "s3:GetBucketVersioning",
          "s3:ListBucketVersions",
        ]
        Resource = [
          aws_s3_bucket.mwaa_dags.arn,
          "${aws_s3_bucket.mwaa_dags.arn}/*"
        ]
      },
      # Allow the DAG to start and monitor the Glue job
      {
        Sid    = "GlueJobAccess"
        Effect = "Allow"
        Action = [
          "glue:StartJobRun",
          "glue:GetJobRun",
          "glue:GetJobRuns",
          "glue:BatchStopJobRun"
        ]
        Resource = aws_glue_job.music_stream_insert.arn
      },
      # MWAA publishes task, scheduler, and webserver logs to CloudWatch
      {
        Sid    = "CloudWatchLogs"
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents",
          "logs:GetLogEvents",
          "logs:GetLogRecord",
          "logs:GetQueryResults",
          "logs:DescribeLogGroups"
        ]
        Resource = "arn:aws:logs:${var.aws_region}:*:log-group:airflow-${var.project_name}-airflow-*"
      },
      # Required for MWAA to report environment health metrics
      {
        Sid      = "CloudWatchMetrics"
        Effect   = "Allow"
        Action   = ["cloudwatch:PutMetricData"]
        Resource = "*"
      },
      # Required for MWAA to publish its own internal metrics
      {
        Sid      = "MWAAPublishMetrics"
        Effect   = "Allow"
        Action   = ["airflow:PublishMetrics"]
        Resource = "arn:aws:airflow:${var.aws_region}:*:environment/${var.project_name}-airflow"
      }
    ]
  })
}

