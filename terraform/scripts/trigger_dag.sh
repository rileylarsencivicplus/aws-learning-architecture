#!/bin/bash
# ─────────────────────────────────────────────
# trigger_dag.sh
#
# Unpauses and triggers the music_stream_dag in MWAA,
# then polls until the Glue job completes.
#
# Usage:
#   bash terraform/scripts/trigger_dag.sh
#
# Requirements:
#   - AWS CLI configured with the antigravity-user profile
#   - MWAA environment must be in AVAILABLE status
#   - curl and python3 available (both included in Git Bash)
# ─────────────────────────────────────────────

set -euo pipefail

PROFILE="antigravity-user"
ENV_NAME="aws-learning-airflow"
DAG_ID="music_stream_dag"
GLUE_JOB="music-stream-insert"
REGION="us-east-1"

# ─────────────────────────────────────────────
# Helper: call the Airflow CLI via MWAA token
# A new token is fetched for every call — they expire in ~60s
# ─────────────────────────────────────────────
airflow_cli() {
  local command="$1"
  local cli_token
  cli_token=$(aws mwaa create-cli-token \
    --name "$ENV_NAME" \
    --profile "$PROFILE" \
    --region "$REGION" \
    --query 'CliToken' \
    --output text)

  curl --silent --request POST "https://${WEB_SERVER}/aws_mwaa/cli" \
    --header "Authorization: Bearer ${cli_token}" \
    --header "Content-Type: text/plain" \
    --data "$command" \
    | python3 -c "
import sys, json, base64
r = json.load(sys.stdin)
stdout = base64.b64decode(r.get('stdout', '')).decode().strip()
stderr = base64.b64decode(r.get('stderr', '')).decode().strip()
if stdout: print(stdout)
if stderr: print('[stderr]', stderr)
"
}

# ─────────────────────────────────────────────
# 1. Check MWAA is AVAILABLE
# ─────────────────────────────────────────────
echo "Checking MWAA environment status..."
STATUS=$(aws mwaa get-environment \
  --name "$ENV_NAME" \
  --profile "$PROFILE" \
  --region "$REGION" \
  --query "Environment.Status" \
  --output text)

if [ "$STATUS" != "AVAILABLE" ]; then
  echo "ERROR: MWAA environment is '$STATUS', not AVAILABLE. Run terraform apply first."
  exit 1
fi
echo "MWAA status: AVAILABLE"

# ─────────────────────────────────────────────
# 2. Get the webserver URL (used by all CLI calls)
# ─────────────────────────────────────────────
WEB_SERVER=$(aws mwaa get-environment \
  --name "$ENV_NAME" \
  --profile "$PROFILE" \
  --region "$REGION" \
  --query "Environment.WebserverUrl" \
  --output text)
echo "Airflow webserver: https://${WEB_SERVER}"

# ─────────────────────────────────────────────
# 3. Unpause the DAG
# ─────────────────────────────────────────────
echo ""
echo "Unpausing DAG '${DAG_ID}'..."
airflow_cli "dags unpause ${DAG_ID}"

# ─────────────────────────────────────────────
# 4. Trigger the DAG
# ─────────────────────────────────────────────
echo ""
echo "Triggering DAG '${DAG_ID}'..."
airflow_cli "dags trigger ${DAG_ID}"

# ─────────────────────────────────────────────
# 5. Poll the Glue job until it finishes
# ─────────────────────────────────────────────
echo ""
echo "Waiting for Glue job '${GLUE_JOB}' to start and complete..."
echo "(This may take up to 60 seconds for Airflow to schedule the task)"

sleep 15  # Give Airflow time to schedule and start the task

MAX_ATTEMPTS=20
ATTEMPT=0

while [ $ATTEMPT -lt $MAX_ATTEMPTS ]; do
  ATTEMPT=$((ATTEMPT + 1))

  GLUE_STATUS=$(aws glue get-job-runs \
    --job-name "$GLUE_JOB" \
    --profile "$PROFILE" \
    --region "$REGION" \
    --max-results 1 \
    --query "JobRuns[0].JobRunState" \
    --output text 2>/dev/null || echo "NONE")

  echo "  [${ATTEMPT}/${MAX_ATTEMPTS}] Glue job status: ${GLUE_STATUS}"

  case "$GLUE_STATUS" in
    SUCCEEDED)
      echo ""
      echo "SUCCESS: Glue job completed successfully."
      echo "You can now run: terraform destroy"
      exit 0
      ;;
    FAILED|ERROR|TIMEOUT|STOPPED)
      echo ""
      echo "ERROR: Glue job ended with status '${GLUE_STATUS}'."
      echo "Check the Glue console for logs: AWS Console -> Glue -> ETL Jobs -> ${GLUE_JOB} -> Runs"
      exit 1
      ;;
    NONE|"None")
      echo "  Glue job not started yet — Airflow may still be scheduling it."
      ;;
  esac

  sleep 15
done

echo ""
echo "TIMEOUT: Glue job did not complete within $((MAX_ATTEMPTS * 15)) seconds."
echo "Check the Airflow UI and Glue console manually."
exit 1
