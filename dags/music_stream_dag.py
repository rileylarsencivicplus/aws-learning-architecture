"""
music_stream_dag.py
-------------------
Airflow DAG that triggers the `music-stream-insert` AWS Glue job once per week.

Schedule: @weekly (every Sunday at 00:00 UTC)
Retry:    1 retry, 5-minute delay between attempts
"""

from datetime import datetime, timedelta

import boto3
from airflow import DAG
from airflow.operators.python import PythonOperator

# ─────────────────────────────────────────────
# Default arguments applied to every task in the DAG
# ─────────────────────────────────────────────
default_args = {
    "owner": "airflow",
    "retries": 1,
    "retry_delay": timedelta(minutes=5),
}

GLUE_JOB_NAME = "music-stream-insert"
AWS_REGION = "us-east-1"


def trigger_glue_job(**context):
    """
    Calls the AWS Glue StartJobRun API for the music-stream-insert job.
    Logs the JobRunId so you can trace it in the Glue console.

    The MWAA execution role's IAM policy must allow glue:StartJobRun
    on this job — that is managed in Terraform (iam.tf).
    """
    client = boto3.client("glue", region_name=AWS_REGION)
    response = client.start_job_run(JobName=GLUE_JOB_NAME)
    run_id = response["JobRunId"]
    print(f"Started Glue job '{GLUE_JOB_NAME}' — JobRunId: {run_id}")
    return run_id


# ─────────────────────────────────────────────
# DAG definition
# ─────────────────────────────────────────────
with DAG(
    dag_id="music_stream_dag",
    default_args=default_args,
    description="Triggers the music-stream-insert Glue job once per week.",
    schedule_interval="@weekly",
    start_date=datetime(2026, 3, 9),  # First Sunday on or after today
    catchup=False,                    # Do not backfill missed runs
    tags=["glue", "music-stream", "learning"],
) as dag:

    trigger = PythonOperator(
        task_id="trigger_glue_job",
        python_callable=trigger_glue_job,
    )
