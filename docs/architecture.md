# AWS Learning Architecture — Diagrams

---

## Overview: What Lives in AWS and How It Connects

```mermaid
flowchart TB
    You(["💻 You\ntrigger_dag.sh"])

    subgraph S3["S3 — File Storage"]
        DAGBucket["📁 mwaa-dags bucket\nHolds: music_stream_dag.py"]
        GlueBucket["📁 glue-assets bucket\nHolds: glue_job_script.py"]
    end

    subgraph NET["VPC — Private Network"]
        MWAA["🌀 Apache Airflow\n(Amazon MWAA)\nSchedules & triggers jobs\nWeekly or on-demand"]
    end

    GLUE["⚙️ AWS Glue Job\nRuns the Python script\nInserts data into Redshift"]

    RS[("🗄️ Redshift Serverless\nData warehouse\nTable: public.music_streams")]

    CW["📋 CloudWatch Logs\nAll logs end up here\n(Airflow + Glue)"]

    You -->|"1 · unpause & trigger DAG"| MWAA
    DAGBucket -->|"Airflow reads the\nDAG file from here"| MWAA
    MWAA -->|"2 · start_job_run()"| GLUE
    GlueBucket -->|"Glue downloads\nits script from here"| GLUE
    GLUE -->|"3 · INSERT row\nvia Redshift Data API"| RS
    MWAA -->|"writes logs"| CW
    GLUE -->|"writes logs"| CW
```

---

## IAM: What Runs as What

> IAM roles are like **badges**. Each AWS service wears a badge that lists what it's allowed to do.
> Without the badge, the service can't talk to anything else.

```mermaid
flowchart LR
    subgraph GlueBadge["🏷️ Glue Job Badge  (aws-learning-glue-job-role)"]
        G1["✅ Read script from S3"]
        G2["✅ Run SQL on Redshift"]
        G3["✅ Write logs to CloudWatch"]
    end

    subgraph MWAABadge["🏷️ Airflow Badge  (aws-learning-mwaa-execution-role)"]
        M1["✅ Read DAG files from S3"]
        M2["✅ Write logs to CloudWatch"]
        M3["✅ Trigger the Glue job"]
        M4["✅ Use internal SQS task queue"]
    end

    GLUE["⚙️ Glue Job"] -->|"wears"| GlueBadge
    MWAA["🌀 Airflow"] -->|"wears"| MWAABadge
```

---

## Network: Why There's a VPC

> Airflow (MWAA) is required by AWS to run inside a private network. It cannot reach the internet
> directly — it goes through a NAT Gateway instead.

```mermaid
flowchart LR
    Internet(["🌐 Internet\nAWS APIs · PyPI"])

    subgraph VPC["VPC — Your Private Network"]
        subgraph Private["Private Subnets (no direct internet)"]
            MWAA["🌀 Airflow Workers\nScheduler · Webserver"]
        end
        NAT["NAT Gateway\n(controlled exit point)"]
    end

    MWAA -->|"outbound requests only"| NAT
    NAT -->|"reaches out on\nAirflow's behalf"| Internet
```
