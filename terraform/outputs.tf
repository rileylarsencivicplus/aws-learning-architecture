output "redshift_workgroup_endpoint" {
  description = "Hostname:port endpoint for the Redshift Serverless workgroup."
  value       = "${data.aws_redshiftserverless_workgroup.main.endpoint[0].address}:${data.aws_redshiftserverless_workgroup.main.endpoint[0].port}"
}

output "redshift_namespace_id" {
  description = "ID of the Redshift Serverless namespace."
  value       = data.aws_redshiftserverless_namespace.main.id
}

output "s3_bucket_name" {
  description = "Name of the S3 bucket where Glue scripts are stored."
  value       = aws_s3_bucket.glue_assets.bucket
}

output "s3_script_path" {
  description = "Full S3 URI of the uploaded Glue job script."
  value       = "s3://${aws_s3_bucket.glue_assets.bucket}/${aws_s3_object.glue_script.key}"
}

output "glue_job_name" {
  description = "Name of the Glue job — use this in the AWS Console to find and run the job."
  value       = aws_glue_job.music_stream_insert.name
}

output "glue_job_role_arn" {
  description = "ARN of the IAM role attached to the Glue job."
  value       = aws_iam_role.glue_job_role.arn
}
