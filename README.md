# aws-learning-architecture

This project uses **Terraform** to provision an AWS data pipeline consisting of:

- **Redshift Serverless** — data warehouse (namespace + workgroup)
- **S3** — stores the Glue Python script
- **AWS Glue** — runs the Python ETL job that inserts a row into Redshift
- **IAM** — role + permissions wiring everything together

---

## Project Structure

```
aws-learning-architecture/
├── glue_job_script.py        # Glue Python script (auto-uploaded to S3 by Terraform)
├── terraform/
│   ├── main.tf               # Provider + backend config
│   ├── variables.tf          # Input variables
│   ├── outputs.tf            # Summary printed after terraform apply
│   ├── s3.tf                 # S3 bucket for Glue scripts
│   ├── iam.tf                # IAM role + permissions for Glue
│   ├── redshift.tf           # Redshift Serverless namespace + workgroup
│   └── glue.tf               # Glue job definition
└── README.md
```

---

## Prerequisites

- [Terraform >= 1.5](https://developer.hashicorp.com/terraform/downloads) installed
- AWS credentials configured (via `~/.aws/credentials` or environment variables)

---

## Deploy

```bash
# 1. Move into the terraform directory
cd terraform

# 2. Download providers (one-time setup)
terraform init

# 3. Preview what will be created (no charges)
terraform plan -var="redshift_admin_password=YourPassword123!"

# 4. Create all resources in AWS
terraform apply -var="redshift_admin_password=YourPassword123!"
```

After `apply` completes, Terraform prints:

- `redshift_workgroup_endpoint` — your Redshift endpoint
- `s3_bucket_name` — the bucket holding your Glue script
- `glue_job_name` — the job name to find in the AWS Console

---

## Run the Glue Job

1. Go to **AWS Console → AWS Glue → ETL Jobs**
2. Click **`music-stream-insert`**
3. Click **Run**
4. Wait ~60 seconds, then check the Run status

---

## Verify the Data

1. Go to **AWS Console → Amazon Redshift → Query Editor v2**
2. Connect to workgroup: `default-workgroup`, database: `dev`
3. Run:

```sql
SELECT * FROM public.music_streams;
```

---

## Password Tips

- Must be 8–64 characters
- Must include at least one uppercase letter, one lowercase letter, and one number
- You can also set it as an environment variable to avoid typing it each time:

**Windows Command Prompt:**

```cmd
set TF_VAR_redshift_admin_password=YourPassword123!
terraform apply
```

**Git Bash:**

```bash
export TF_VAR_redshift_admin_password=YourPassword123!
terraform apply
```
