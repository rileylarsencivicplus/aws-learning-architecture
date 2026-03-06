# AWS Learning Architecture — Complete Walkthrough

## What This Project Does (The Big Picture)

This is a **learning-grade data pipeline** built on AWS and managed entirely by Terraform. The goal is to simulate what a real data engineering stack looks like:

1. **Airflow** (MWAA) acts as the orchestrator — it runs a DAG on a schedule.
2. The DAG **triggers a Glue job** that runs a Python script.
3. The Glue script **inserts a row of fake music-stream data** into a **Redshift Serverless** database.

Everything is disposable by design — you run `terraform apply`, do the demo, then `terraform destroy` to avoid charges.

See [`architecture.md`](./architecture.md) for the full dependency and data-flow diagrams.

---

## Repository Layout

```
aws-learning-architecture/
│
├── glue_job_script.py          ← The Python script Glue actually executes
├── dags/
│   └── music_stream_dag.py     ← The Airflow DAG definition
├── docs/
│   ├── walkthrough.md          ← This file
│   └── architecture.md         ← Mermaid diagrams
│
└── terraform/
    ├── main.tf                 ← Provider config & backend
    ├── variables.tf            ← Input variable declarations
    ├── vpc.tf                  ← Networking (VPC, subnets, NAT, routes)
    ├── s3.tf                   ← S3 bucket for Glue scripts
    ├── iam.tf                  ← IAM roles & policies for Glue + MWAA
    ├── glue.tf                 ← AWS Glue job definition
    ├── redshift.tf             ← Redshift Serverless namespace + workgroup
    ├── mwaa.tf                 ← MWAA S3 bucket + environment
    ├── outputs.tf              ← What Terraform prints after apply
    └── scripts/
        ├── init.ps1            ← Cleans and re-initializes Terraform
        ├── id.ps1              ← Verifies AWS identity (sanity check)
        └── trigger_dag.sh      ← End-to-end automation: unpause → trigger → poll
```

---

## Phase 1 — Terraform Configuration Files (The Setup)

### `main.tf` — The Root Config

This is where Terraform itself is configured. It does three things:

| Block                | Purpose                                                                                                                                                                    |
| -------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `required_version`   | Ensures you're using Terraform ≥ 1.14.5. Older versions may not support newer resource attributes.                                                                         |
| `required_providers` | Pins the AWS provider to ≥ 5.100.0 (needed for Glue 5.x Python Shell support) and the `random` provider (used to generate a unique S3 suffix).                             |
| `backend "local" {}` | Terraform state is saved to `terraform.tfstate` on your local disk. For a real team project, this would be replaced with an S3 backend so multiple people can share state. |
| `provider "aws"`     | Sets the default region from `var.aws_region` and applies `Project` + `ManagedBy` tags to **every** resource automatically via `default_tags`.                             |

### `variables.tf` — Input Parameters

Declares the four inputs the project accepts:

| Variable                  | Default              | Why it exists                                                                                                                         |
| ------------------------- | -------------------- | ------------------------------------------------------------------------------------------------------------------------------------- |
| `aws_region`              | `us-east-1`          | Every resource in this project targets one region. Centralizing it here means changing one value moves everything.                    |
| `project_name`            | `aws-learning`       | Used as a prefix on every resource name (S3 buckets, IAM roles, etc.) so you can instantly identify project resources in the console. |
| `redshift_database_name`  | `dev`                | The name of the database Redshift auto-creates inside the namespace.                                                                  |
| `redshift_admin_password` | _(none — sensitive)_ | No default on purpose. You supply this via `terraform.tfvars` or `-var` at the command line so it's never committed to Git.           |

---

## Phase 2 — Terraform Execution Order (What Happens During `apply`)

Terraform builds a **dependency graph** from implicit and explicit `depends_on` references. Resources with no dependencies are created in parallel; those that reference others wait. See [`architecture.md`](./architecture.md) for the full visual graph.

Broadly, the order is:

1. **`random_id`** (bucket suffix) + **VPC** — no dependencies, created in parallel
2. **Subnets, IGW, EIP** — depend on VPC
3. **NAT Gateway** — depends on IGW + EIP + public subnet
4. **S3 buckets** — depend on the random suffix
5. **Bucket configs + object uploads** — depend on their buckets
6. **Redshift namespace → workgroup** — sequential; workgroup needs namespace
7. **IAM roles → IAM policies** — policies reference Redshift workgroup ARN + Glue job ARN
8. **Glue job** — depends on the S3 object + both IAM policies
9. **MWAA environment** — last; depends on the DAG file, IAM policy, and NAT Gateway

> **Note:** MWAA takes ~20–30 minutes to provision because AWS is standing up a fully managed Airflow cluster internally.

---

## Phase 3 — File-by-File Deep Dive

### `vpc.tf` — The Network Layer

MWAA is the only resource that **requires** a VPC. AWS does not let you run MWAA on the public internet — it must live inside private subnets.

| Resource                       | What it is                                                     | Why it's needed                                                                                 |
| ------------------------------ | -------------------------------------------------------------- | ----------------------------------------------------------------------------------------------- |
| `aws_vpc.main` (`10.0.0.0/16`) | The isolated network container                                 | All MWAA components live here. DNS support + hostnames required for MWAA's internal resolution. |
| `aws_subnet.private` (×2)      | `10.0.1.0/24` and `10.0.2.0/24` in `us-east-1a` / `us-east-1b` | MWAA **requires at least 2 private subnets in different AZs** for high availability.            |
| `aws_subnet.public` (×2)       | `10.0.101.0/24` and `10.0.102.0/24`                            | Used only to host the NAT Gateway. MWAA workers never sit here.                                 |
| `aws_internet_gateway.main`    | Gives the VPC a path to the internet                           | Required for the NAT Gateway to route traffic outward.                                          |
| `aws_eip.nat`                  | A static public IP                                             | Attached to the NAT Gateway so outbound traffic has a fixed source IP.                          |
| `aws_nat_gateway.main`         | Routes outbound traffic from private subnets                   | MWAA workers need it to reach AWS APIs and install Python packages via HTTPS.                   |
| `aws_route_table.public`       | Route `0.0.0.0/0 → IGW`                                        | Lets the NAT Gateway itself reach the internet.                                                 |
| `aws_route_table.private`      | Route `0.0.0.0/0 → NAT`                                        | Lets MWAA workers make outbound calls without a public IP.                                      |

> The `count = 2` pattern on subnets is Terraform's loop — `count.index` gives `0` or `1`, mapping to `us-east-1a` / `us-east-1b` via `local.azs`.

---

### `s3.tf` — Glue Assets Bucket

| Resource                                             | Purpose                                                                                                                                                                         |
| ---------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `random_id.bucket_suffix`                            | S3 bucket names are globally unique across all AWS accounts. Appending 4 random bytes as hex prevents naming collisions.                                                        |
| `aws_s3_bucket.glue_assets`                          | Stores the Glue Python script. Named `aws-learning-glue-assets-<suffix>`.                                                                                                       |
| `aws_s3_bucket_public_access_block`                  | Blocks all public access — a script bucket should never be publicly readable.                                                                                                   |
| `aws_s3_bucket_versioning`                           | Keeps a full history of every script upload. Useful for rollbacks.                                                                                                              |
| `aws_s3_bucket_server_side_encryption_configuration` | Encrypts objects at rest with AWS-managed AES-256 keys — free and zero-config.                                                                                                  |
| `aws_s3_object.glue_script`                          | Reads `glue_job_script.py` from your local disk and uploads it to `scripts/glue_job_script.py`. `etag = filemd5(...)` means Terraform only re-uploads when the content changes. |

---

### `redshift.tf` — The Data Warehouse

Redshift Serverless has a two-layer architecture:

| Resource                           | Analogy               | What it does                                                                                          |
| ---------------------------------- | --------------------- | ----------------------------------------------------------------------------------------------------- |
| `aws_redshiftserverless_namespace` | The "database server" | Holds databases, users, and credentials. Setting `db_name = "dev"` auto-creates the database.         |
| `aws_redshiftserverless_workgroup` | The "compute engine"  | The actual query processing layer. `price_performance_target { level = 50 }` balances cost vs. speed. |

> Serverless means you don't pay for idle time the way you would with a provisioned cluster — Redshift scales to zero when not in use.

---

### `iam.tf` — The Permission Layer

Two completely independent IAM roles, each with least-privilege:

#### Glue IAM Role

When the Glue job runs, it assumes this role. The trust policy allows **only the Glue service** to assume it.

| Permission set                     | What it grants                                                                                                                                                     |
| ---------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `AWSGlueServiceRole` (AWS managed) | Basic Glue permissions: CloudWatch logging, reading job metadata, etc.                                                                                             |
| `GlueRedshiftAndS3Access` (inline) | `s3:GetObject/ListBucket` on the script bucket; `redshift-data:ExecuteStatement` + related actions; `redshift-serverless:GetCredentials/GetWorkgroup` for IAM auth |

#### MWAA IAM Role

Assumed by the entire Airflow environment. The trust policy allows both `airflow.amazonaws.com` and `airflow-env.amazonaws.com`.

| Permission                      | Why                                                              |
| ------------------------------- | ---------------------------------------------------------------- |
| S3 read on DAG bucket           | MWAA must read DAG files                                         |
| CloudWatch Logs                 | Every scheduler/worker/task log goes here                        |
| SQS                             | MWAA uses Celery internally, which uses SQS as its task queue    |
| KMS                             | Encrypts/decrypts SQS messages (scoped to AWS-managed keys only) |
| `glue:StartJobRun` + monitoring | Lets the DAG actually call Glue — scoped to exactly one job ARN  |

---

### `glue.tf` — The ETL Job

| Setting                       | Value                                       | Why                                                                                      |
| ----------------------------- | ------------------------------------------- | ---------------------------------------------------------------------------------------- |
| `command.name`                | `pythonshell`                               | Not Spark. A plain Python runner — far cheaper and faster for lightweight tasks.         |
| `python_version`              | `3.9`                                       | Required for Python Shell on Glue 5.1.                                                   |
| `script_location`             | S3 URI of the uploaded script               | Glue pulls from S3 at runtime — your local file is never used directly.                  |
| `default_arguments`           | `WORKGROUP_NAME`, `DATABASE_NAME`, `REGION` | Injected as environment variables; separates config from code.                           |
| `--additional-python-modules` | `boto3>=1.26.0,botocore>=1.29.0`            | The bundled boto3 is too old to support Redshift Serverless's `WorkgroupName` parameter. |
| `max_capacity`                | `0.0625` DPU                                | The minimum billing unit — the cheapest option.                                          |
| `max_concurrent_runs`         | `1`                                         | Prevents accidental duplicate inserts if the DAG fires twice.                            |
| `glue_version`                | `5.1`                                       | Required by this AWS account; supports Python 3.11.                                      |

---

### `mwaa.tf` — The Orchestrator

#### MWAA DAGs Bucket

MWAA **cannot share** the Glue assets bucket — it requires its own dedicated S3 bucket. Versioning is mandatory because MWAA uses object version IDs to detect when DAG files have been updated.

`aws_s3_object.mwaa_dag` uploads `dags/music_stream_dag.py` to the `dags/` prefix. The `dag_s3_path = "dags/"` setting in the environment tells Airflow to watch that prefix.

#### Security Group

| Rule                                     | Why                                                                                      |
| ---------------------------------------- | ---------------------------------------------------------------------------------------- |
| Self-referential ingress (all protocols) | The scheduler, workers, and webserver communicate on arbitrary ports within the same SG. |
| Unrestricted egress                      | MWAA must reach S3, CloudWatch, SQS, Glue, and PyPI over HTTPS.                          |

#### The MWAA Environment

| Setting                 | Value                                      | Why                                                                       |
| ----------------------- | ------------------------------------------ | ------------------------------------------------------------------------- |
| `environment_class`     | `mw1.small`                                | Cheapest tier (~$0.49/hr). Suitable for learning.                         |
| `airflow_version`       | `2.10.3`                                   | Pinned for reproducibility.                                               |
| `execution_role_arn`    | Points to `mwaa_execution_role`            | The IAM role MWAA assumes for all its operations.                         |
| `dag_s3_path`           | `dags/`                                    | The S3 prefix MWAA scans for `.py` files.                                 |
| `network_configuration` | Both private subnets + MWAA security group | Workers live in private subnets with outbound access via NAT.             |
| `logging_configuration` | All components at INFO                     | Scheduler, worker, task, webserver, and DAG processing logs → CloudWatch. |

> **Critical:** `depends_on` explicitly waits for the DAG file upload, the IAM policy (which references the Glue job ARN), and the NAT Gateway. Without NAT, MWAA provisioning fails — it can't reach AWS APIs from private subnets.

---

### `outputs.tf` — What Terraform Tells You After Apply

| Output                        | What to do with it                                     |
| ----------------------------- | ------------------------------------------------------ |
| `redshift_workgroup_endpoint` | Connect from a SQL client (DBeaver, pgAdmin, etc.)     |
| `redshift_namespace_id`       | Reference in the AWS Console or CLI                    |
| `s3_bucket_name`              | The Glue assets bucket name with its random suffix     |
| `s3_script_path`              | Full `s3://` URI of the uploaded Glue script           |
| `glue_job_name`               | Find the job in the AWS Console → Glue → ETL Jobs      |
| `glue_job_role_arn`           | IAM role ARN attached to the job                       |
| `mwaa_webserver_url`          | **Open this in your browser** to access the Airflow UI |

---

## Phase 4 — The Application Code

### `glue_job_script.py` — What Actually Runs in AWS

1. **Reads its config** via `getResolvedOptions()` — the AWS Glue SDK function that parses `default_arguments` defined in `glue.tf`. Falls back to hardcoded defaults when run locally.
2. **Creates a Redshift Data API client** (`boto3.client('redshift-data')`) — the modern, IAM-based way to run SQL against Redshift Serverless. No connection strings or passwords.
3. **Creates the table** (`CREATE TABLE IF NOT EXISTS public.music_streams`) — idempotent, safe to run multiple times.
4. **Inserts a single row** with hardcoded data: `user_01`, `The Midnight`, `Sunset`, live timestamp, 245s duration.
5. **Polls** the Data API for completion — the API is async, so the script checks every second until `FINISHED`, `FAILED`, or `ABORTED`.

### `dags/music_stream_dag.py` — The Airflow Orchestration

| Setting             | Value                  | Why                                                                          |
| ------------------- | ---------------------- | ---------------------------------------------------------------------------- |
| `schedule_interval` | `@weekly`              | Every Sunday at 00:00 UTC                                                    |
| `catchup = False`   | set                    | Prevents Airflow from backfilling all missed weekly runs since `start_date`. |
| `start_date`        | `datetime(2026, 3, 9)` | First Sunday after the project was created. No runs scheduled before this.   |
| `retries`           | 1 with 5-min delay     | Retries once on transient API failures before marking the run failed.        |

The single task `trigger_glue_job` uses a `PythonOperator` calling `boto3.client("glue").start_job_run()`. The DAG **fires** the job and logs the `JobRunId` — it does not wait for the job to finish. That polling is handled by `trigger_dag.sh`.

---

## Phase 5 — The Helper Scripts

### `terraform/scripts/init.ps1` — Clean Re-initialization

Deletes `.terraform/` and `.terraform.lock.hcl` before running `terraform init`. Useful when switching provider versions or hitting plugin cache issues — the equivalent of a clean install.

### `terraform/scripts/id.ps1` — Identity Check

Runs `aws sts get-caller-identity` to confirm which AWS account and IAM user Terraform will use. Always run before `apply` to verify you're targeting the right account.

### `terraform/scripts/trigger_dag.sh` — End-to-End Automation

```
Step 1: Verify MWAA status == AVAILABLE (exit if not ready)
Step 2: Fetch the Airflow webserver URL from the MWAA API
Step 3: Unpause the DAG  (new DAGs start paused in Airflow by default)
Step 4: Trigger an immediate DAG run
Step 5: Poll aws glue get-job-runs every 15s (up to 5 minutes)
         SUCCEEDED  → print success, suggest terraform destroy
         FAILED/ERROR/TIMEOUT/STOPPED → print error, point to Glue console
         NONE → Airflow is still scheduling, keep waiting
```

The `airflow_cli()` helper fetches a short-lived (~60s) MWAA CLI bearer token via `aws mwaa create-cli-token`, then POSTs the CLI command to the MWAA webserver's `/aws_mwaa/cli` endpoint. The response is base64-encoded JSON that the inline Python decodes.

---

## The Complete Data Flow (End to End)

```
bash terraform/scripts/trigger_dag.sh
  │
  ├─ aws mwaa create-cli-token → short-lived bearer token
  ├─ POST /aws_mwaa/cli "dags unpause music_stream_dag"
  ├─ POST /aws_mwaa/cli "dags trigger music_stream_dag"
  │
  └─ [MWAA Worker] PythonOperator → boto3 glue.start_job_run("music-stream-insert")
       │
       └─ [Glue Python Shell]
            ├─ Pulls glue_job_script.py from S3 (glue-assets bucket)
            ├─ Reads WORKGROUP_NAME, DATABASE_NAME, REGION from job args
            │
            ├─ redshift-data.execute_statement(
            │    WorkgroupName="default-workgroup", Database="dev",
            │    Sql="CREATE TABLE IF NOT EXISTS public.music_streams (...)"
            │  ) → polls until FINISHED
            │
            └─ redshift-data.execute_statement(
                 Sql="INSERT INTO public.music_streams VALUES ('user_01', ...)"
               ) → polls until FINISHED
                    │
                    └─ [Redshift Serverless] Row stored in dev.public.music_streams

  trigger_dag.sh polls aws glue get-job-runs → SUCCEEDED → exit 0
```

---

## Teardown

```powershell
cd terraform
terraform destroy -var="redshift_admin_password=YourPass123"
```

Deletes **everything** in reverse dependency order. The NAT Gateway and Elastic IP are the most important resources to destroy — they incur charges even when idle.
