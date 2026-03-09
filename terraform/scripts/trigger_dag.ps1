# ─────────────────────────────────────────────
# trigger_dag.ps1
#
# Unpauses and triggers the music_stream_dag in MWAA,
# then polls until the Glue job completes.
#
# Usage:
#   .\terraform\scripts\trigger_dag.ps1
#
# Requirements:
#   - AWS CLI configured with the antigravity-user profile
#   - MWAA environment must be in AVAILABLE status
# ─────────────────────────────────────────────

$ErrorActionPreference = "Stop"

$PROFILE   = "antigravity-user"
$ENV_NAME  = "aws-learning-airflow"
$DAG_ID    = "music_stream_dag"
$GLUE_JOB  = "music-stream-insert"
$REGION    = "us-east-1"

# ─────────────────────────────────────────────
# Helper: call the Airflow CLI via MWAA token
# A new token is fetched for every call — they expire in ~60s
# ─────────────────────────────────────────────
function Invoke-AirflowCli {
    param([string]$Command)

    $cliToken = aws mwaa create-cli-token `
        --name $ENV_NAME `
        --profile $PROFILE `
        --region $REGION `
        --query "CliToken" `
        --output text

    $response = Invoke-RestMethod `
        -Uri "https://${WEB_SERVER}/aws_mwaa/cli" `
        -Method POST `
        -Headers @{
            "Authorization" = "Bearer $cliToken"
            "Content-Type"  = "text/plain"
        } `
        -Body $Command

    $stdout = if ($response.stdout) { [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($response.stdout)).Trim() } else { "" }
    $stderr = if ($response.stderr) { [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($response.stderr)).Trim() } else { "" }

    if ($stdout) { Write-Host $stdout }
    if ($stderr) { Write-Host "[stderr] $stderr" }
}

# ─────────────────────────────────────────────
# 1. Check MWAA is AVAILABLE
# ─────────────────────────────────────────────
Write-Host "Checking MWAA environment status..."
$STATUS = aws mwaa get-environment `
    --name $ENV_NAME `
    --profile $PROFILE `
    --region $REGION `
    --query "Environment.Status" `
    --output text

if ($STATUS -ne "AVAILABLE") {
    Write-Error "ERROR: MWAA environment is '$STATUS', not AVAILABLE. Run terraform apply first."
    exit 1
}
Write-Host "MWAA status: AVAILABLE"

# ─────────────────────────────────────────────
# 2. Get the webserver URL (used by all CLI calls)
# ─────────────────────────────────────────────
$WEB_SERVER = aws mwaa get-environment `
    --name $ENV_NAME `
    --profile $PROFILE `
    --region $REGION `
    --query "Environment.WebserverUrl" `
    --output text
Write-Host "Airflow webserver: https://${WEB_SERVER}"

# ─────────────────────────────────────────────
# 3. Unpause the DAG
# ─────────────────────────────────────────────
Write-Host ""
Write-Host "Unpausing DAG '${DAG_ID}'..."
Invoke-AirflowCli "dags unpause ${DAG_ID}"

# ─────────────────────────────────────────────
# 4. Trigger the DAG
# ─────────────────────────────────────────────
Write-Host ""
Write-Host "Triggering DAG '${DAG_ID}'..."
Invoke-AirflowCli "dags trigger ${DAG_ID}"

# ─────────────────────────────────────────────
# 5. Poll the Glue job until it finishes
# ─────────────────────────────────────────────
Write-Host ""
Write-Host "Waiting for Glue job '${GLUE_JOB}' to start and complete..."
Write-Host "(This may take up to 60 seconds for Airflow to schedule the task)"

Start-Sleep -Seconds 15  # Give Airflow time to schedule and start the task

$MAX_ATTEMPTS = 20
$ATTEMPT = 0

while ($ATTEMPT -lt $MAX_ATTEMPTS) {
    $ATTEMPT++

    try {
        $GLUE_STATUS = aws glue get-job-runs `
            --job-name $GLUE_JOB `
            --profile $PROFILE `
            --region $REGION `
            --max-results 1 `
            --query "JobRuns[0].JobRunState" `
            --output text 2>$null
    } catch {
        $GLUE_STATUS = "NONE"
    }

    if (-not $GLUE_STATUS) { $GLUE_STATUS = "NONE" }

    Write-Host "  [${ATTEMPT}/${MAX_ATTEMPTS}] Glue job status: ${GLUE_STATUS}"

    switch ($GLUE_STATUS) {
        "SUCCEEDED" {
            Write-Host ""
            Write-Host "SUCCESS: Glue job completed successfully."
            Write-Host "You can now run: terraform destroy"
            exit 0
        }
        { $_ -in @('FAILED','ERROR','TIMEOUT','STOPPED') } {
            Write-Host ''
            Write-Host "ERROR: Glue job ended with status '${GLUE_STATUS}'."
            Write-Host "Check the Glue console for logs: AWS Console -> Glue -> ETL Jobs -> ${GLUE_JOB} -> Runs"
            exit 1
        }
        { $_ -in @('NONE','None') } {
            Write-Host '  Glue job not started yet — Airflow may still be scheduling it.'
        }
    }

    Start-Sleep -Seconds 15
}

Write-Host ""
Write-Host "TIMEOUT: Glue job did not complete within $($MAX_ATTEMPTS * 15) seconds."
Write-Host "Check the Airflow UI and Glue console manually."
exit 1
