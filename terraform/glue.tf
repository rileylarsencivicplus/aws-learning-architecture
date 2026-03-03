# ─────────────────────────────────────────────
# AWS Glue Job — music-stream-insert
#
# This is a Python Shell job (not Spark).
# Python Shell = runs a plain Python script, ideal for lightweight tasks
# like inserting a single row into Redshift.
# ─────────────────────────────────────────────
resource "aws_glue_job" "music_stream_insert" {
  name     = "music-stream-insert"
  role_arn = aws_iam_role.glue_job_role.arn

  command {
    # "pythonshell" runs a plain Python script.
    # The alternative "glueetl" would be for Spark/big-data processing.
    # python_version "3.9" is required for Glue 4.0 Python Shell jobs.
    name            = "pythonshell"
    python_version  = "3.9"
    script_location = "s3://${aws_s3_bucket.glue_assets.bucket}/${aws_s3_object.glue_script.key}"
  }

  # These are environment variables passed into the script at runtime.
  # The script reads them via getResolvedOptions() so you can change
  # these values here in Terraform without editing the Python file.
  default_arguments = {
    "--WORKGROUP_NAME"      = aws_redshiftserverless_workgroup.main.workgroup_name
    "--DATABASE_NAME"       = var.redshift_database_name
    "--REGION"              = var.aws_region
    "--job-language"        = "python"
    "--enable-job-insights" = "true"
    # Force a newer boto3 so that WorkgroupName is supported in
    # redshift-data:ExecuteStatement (required for Redshift Serverless).
    # The SDK bundled in Glue 5.1 Python Shell is too old and only knows
    # about provisioned-cluster params (ClusterIdentifier, DbUser, etc.).
    "--additional-python-modules" = "boto3>=1.26.0,botocore>=1.29.0"
  }

  # Max concurrent runs: 1 (safe default, prevents accidental duplicate inserts)
  execution_property {
    max_concurrent_runs = 1
  }

  # Glue version 5.0 — required by this AWS account. Supports Python 3.11 (pythonshell).
  glue_version = "5.1"

  # Max capacity in DPUs. 0.0625 is the minimum for Python Shell (cheapest).
  max_capacity = 0.0625

  tags = {
    Name = "music-stream-insert"
  }

  depends_on = [
    aws_s3_object.glue_script,
    aws_iam_role_policy.glue_redshift_s3_policy,
    aws_iam_role_policy_attachment.glue_service_role
  ]
}
