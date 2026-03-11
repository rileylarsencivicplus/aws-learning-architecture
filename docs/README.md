# aws-learning-architecture

A learning project that uses **Terraform** to provision a full AWS data pipeline. Infrastructure is defined as code so it can be spun up, experimented with, and torn down repeatably with simple CLI commands.

### What gets built

- **VPC** — isolated network with public/private subnets required by MWAA
- **Redshift Serverless** — data warehouse that stores music streaming rows
- **S3** — two buckets: one for Glue scripts, one for Airflow DAGs
- **AWS Glue** — Python job that inserts one row of music stream data into Redshift
- **Amazon MWAA** — managed Airflow (`mw1.small`) that schedules the Glue job weekly
- **IAM** — least-privilege roles and policies wiring every service together

---

## Project Structure

```
aws-learning-architecture/
├── glue_job_script.py          # Glue Python script (auto-uploaded to S3 by Terraform)
├── dags/
│   └── music_stream_dag.py     # Airflow DAG (auto-uploaded to S3 by Terraform)
├── terraform/
│   ├── main.tf                 # Terraform + AWS provider config
│   ├── variables.tf            # All input variables (region, project name, passwords)
│   ├── outputs.tf              # Values printed after terraform apply
│   ├── vpc.tf                  # VPC, subnets, NAT gateway (required by MWAA)
│   ├── s3.tf                   # S3 bucket for Glue scripts
│   ├── iam.tf                  # IAM roles and policies for Glue and MWAA
│   ├── redshift.tf             # Redshift Serverless namespace + workgroup
│   ├── glue.tf                 # Glue job definition
│   ├── mwaa.tf                 # MWAA environment + DAG S3 bucket
│   └── scripts/
│       ├── init.ps1            # Clean re-initialization helper
│       ├── id.ps1              # Verify AWS identity before apply
│       └── trigger_dag.ps1     # Unpause, trigger, and poll the DAG end-to-end
└── README.md
```

---

## Terraform Files

### `main.tf` — Provider & Backend

Declares the minimum Terraform version, the AWS provider version, and the AWS region. Sets up the local state backend (state is stored in `terraform.tfstate` on disk). This is the entry point Terraform reads first on every `init` and `plan`.

---

### `variables.tf` — Input Variables

Defines every configurable input the rest of the codebase references via `var.*`. Nothing gets hardcoded in resource files — values flow in from here.

| Variable                  | Default             | Purpose                                                 |
| ------------------------- | ------------------- | ------------------------------------------------------- |
| `aws_region`              | `us-east-1`         | Region all resources deploy into                        |
| `project_name`            | `aws-learning`      | Prefix applied to every resource name                   |
| `redshift_database_name`  | `dev`               | Name of the database created inside the namespace       |
| `redshift_admin_password` | _(none — prompted)_ | Admin credentials for Redshift; sensitive, never logged |

---

### `outputs.tf` — Post-Apply Summary

Values that Terraform prints to the terminal after a successful `apply`. Useful for copy-pasting endpoints and URLs without having to look them up in the AWS Console.

| Output                        | What it shows                                |
| ----------------------------- | -------------------------------------------- |
| `redshift_workgroup_endpoint` | `host:port` for connecting to Redshift       |
| `redshift_namespace_id`       | ID of the Redshift namespace                 |
| `s3_bucket_name`              | Name of the Glue assets bucket               |
| `s3_script_path`              | Full `s3://` URI of the uploaded Glue script |
| `glue_job_name`               | Job name to find in the Glue console         |
| `glue_job_role_arn`           | ARN of the Glue IAM role                     |
| `mwaa_webserver_url`          | HTTPS link to the Airflow web UI             |

---

### `vpc.tf` — Networking (Required by MWAA)

Provisions the VPC that Amazon MWAA must run inside. MWAA requires at least two private subnets in different Availability Zones so that its components can be distributed for high availability. Private subnets have no direct internet route — they reach the internet (e.g. for downloading Python packages) through a NAT Gateway sitting in a public subnet.

**Resources created:**

- `aws_vpc` — `10.0.0.0/16` address space, DNS enabled
- `aws_subnet` × 2 private — `us-east-1a` and `us-east-1b`, for MWAA workers
- `aws_subnet` × 2 public — same AZs, used only to host the NAT Gateway
- `aws_internet_gateway` — gives the public subnets a route to the internet
- `aws_eip` + `aws_nat_gateway` — NAT placed in `us-east-1a` public subnet
- `aws_route_table` × 2 + associations — private routes via NAT, public routes via IGW

---

### `s3.tf` — Glue Assets Bucket

Creates a private, versioned, encrypted S3 bucket that Glue uses to read the Python script at job runtime. Terraform uploads `glue_job_script.py` to `scripts/` inside this bucket and recalculates the upload whenever the file content changes (`etag` check).

**Why separate from the MWAA bucket?** — MWAA requires its own dedicated bucket; the two cannot share one.

---

### `iam.tf` — Roles & Policies

All IAM configuration lives here in one place so permissions are easy to audit. Two roles exist:

**Glue job role** (`aws-learning-glue-job-role`)

- Trust: `glue.amazonaws.com`
- Attached managed policy: `AWSGlueServiceRole` (basic Glue startup permissions)
- Inline policy: S3 read on the Glue bucket, Redshift Data API execution, Redshift Serverless credential retrieval

**MWAA execution role** (`aws-learning-mwaa-execution-role`)

- Trust: `airflow.amazonaws.com` + `airflow-env.amazonaws.com`
- Inline policy: S3 read/write on the DAG bucket, `glue:StartJobRun`/`GetJobRun` on the Glue job, CloudWatch log publishing, MWAA metric publishing

---

### `redshift.tf` — Redshift Serverless

Creates the Redshift Serverless **namespace** and **workgroup** from scratch. Using `resource` blocks (not `data` blocks) means Terraform owns the full lifecycle — it will create, update, and destroy them.

- **Namespace** (`default-namespace`) — logical container for databases and users. Setting `db_name = "dev"` causes Redshift to automatically create that database on first provision.
- **Workgroup** (`default-workgroup`) — the compute layer. Configured with a price-performance target of 50 (balanced cost vs. speed). Depends on the namespace so Terraform always creates them in order.

---

### `glue.tf` — Glue Job Definition

Defines the `music-stream-insert` Python Shell job. Key configuration:

- **Type:** `pythonshell` (plain Python, not Spark — appropriate for a single-row insert)
- **Glue version:** 5.1 with Python 3.9
- **Capacity:** `0.0625` DPUs (minimum — cheapest option)
- **Default arguments:** passes `WORKGROUP_NAME`, `DATABASE_NAME`, and `REGION` into the script as environment variables so the Python file never needs to be edited to change targets
- **Dependencies:** waits for the S3 script upload and IAM policy to exist before creating the job

---

### `mwaa.tf` — Airflow Environment & DAG Bucket

Provisions everything needed to run Apache Airflow via Amazon MWAA.

**DAG S3 bucket** — A dedicated, versioned, encrypted bucket. MWAA polls the `dags/` prefix in this bucket and picks up new or updated DAG files automatically. Terraform uploads `dags/music_stream_dag.py` here.

**Security group** — Attached to the MWAA environment. Has a self-referential ingress rule (allows Airflow components to talk to each other) and open egress (allows HTTPS traffic out for package downloads).

**MWAA environment** (`aws-learning-airflow`)

- Class: `mw1.small` (~$0.49/hr — smallest and cheapest)
- Airflow version: 2.10.3
- Runs inside the two private subnets created in `vpc.tf`
- Full CloudWatch logging enabled for the scheduler, workers, webserver, task logs, and DAG processor — all visible in the Airflow UI and CloudWatch

> **Cost note:** MWAA charges by the hour regardless of DAG activity. Run `terraform destroy` after each learning session to stop billing.

---

## Prerequisites

- [Terraform >= 1.14](https://developer.hashicorp.com/terraform/downloads) installed
- AWS credentials configured (via `~/.aws/credentials` or environment variables)

---

## Deploy

```bash
# 1. Move into the terraform directory
cd terraform

# 2. Download providers (one-time setup)
terraform init

# 3. Preview what will be created (~25 resources)
terraform plan

# 4. Create all resources — Terraform will prompt for the Redshift admin password
terraform apply
```

MWAA takes approximately **20 minutes** to provision after `apply` completes. Once ready, the `mwaa_webserver_url` output will be clickable.

---

## Trigger the Pipeline

Once MWAA shows `AVAILABLE` (check with `aws mwaa get-environment --name aws-learning-airflow --query Environment.Status`), run the automation script from the repo root:

```powershell
.\terraform\scripts\trigger_dag.ps1
```

The script will:

1. Confirm the MWAA environment is `AVAILABLE`
2. Unpause `music_stream_dag` (new DAGs always start paused)
3. Trigger an immediate manual run
4. Poll `aws glue get-job-runs` every 15 seconds until the Glue job `SUCCEEDED` or fails
5. Print the result and remind you to run `terraform destroy`

> **Alternatively** — open the `mwaa_webserver_url` output in your browser to access the Airflow UI and trigger the DAG manually from there.

---

## Verify the Data in Redshift

**Option A — AWS CLI (quickest)**

```powershell
# Submit the query and capture the statement ID
$id = (aws redshift-data execute-statement `
    --workgroup-name default-workgroup `
    --database dev `
    --sql "SELECT * FROM public.music_streams;" `
    --profile antigravity-user --region us-east-1 `
    --query Id --output text)

# Wait a few seconds, then retrieve results
Start-Sleep -Seconds 4
aws redshift-data get-statement-result --id $id `
    --profile antigravity-user --region us-east-1 --output json
```

**Option B — AWS Console**

1. Go to **AWS Console → Amazon Redshift → Query Editor v2**
2. Connect to workgroup: `default-workgroup`, database: `dev`
3. Run:

```sql
SELECT * FROM public.music_streams;
```

---

## Teardown

```bash
# In Git Bash — destroys all resources and stops all billing
terraform destroy
```

> After destroying, open **AWS Billing → Cost Explorer**, filter by service to see the actual MWAA spend for your session.

---

## Password Tips

Redshift admin password requirements:

- 8–64 characters
- At least one uppercase letter, one lowercase letter, and one number

To avoid typing it every time, set it as an environment variable:

**Git Bash:**

```bash
export TF_VAR_redshift_admin_password=YourPassword123!
terraform apply
```

**Windows Command Prompt:**

```cmd
set TF_VAR_redshift_admin_password=YourPassword123!
terraform apply
```
