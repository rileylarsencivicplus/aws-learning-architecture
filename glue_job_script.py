import boto3
import sys
import datetime
import time

# ─────────────────────────────────────────────
# Read configuration from Glue job arguments
# (passed in from Terraform via default_arguments).
# Falls back to hardcoded defaults for local/standalone execution.
# ─────────────────────────────────────────────
def get_args():
    defaults = {
        '--WORKGROUP_NAME': 'default-workgroup',
        '--DATABASE_NAME':  'dev',
        '--REGION':         'us-east-1',
    }
    # When running inside Glue, use getResolvedOptions to read job args
    try:
        from awsglue.utils import getResolvedOptions
        args = getResolvedOptions(sys.argv, ['WORKGROUP_NAME', 'DATABASE_NAME', 'REGION'])
        return {
            'workgroup': args['WORKGROUP_NAME'],
            'database':  args['DATABASE_NAME'],
            'region':    args['REGION'],
        }
    except (ImportError, Exception):
        # Running locally – fall back to defaults
        return {
            'workgroup': defaults['--WORKGROUP_NAME'],
            'database':  defaults['--DATABASE_NAME'],
            'region':    defaults['--REGION'],
        }


def run_glue_job():
    """
    AWS Glue Job to insert a single row of music streaming data
    into the Redshift Serverless workgroup provisioned by Terraform.

    Prerequisites (all handled by Terraform):
      - Glue job role must have redshift-data:ExecuteStatement permission
      - Redshift Serverless workgroup 'default-workgroup' must exist
    """

    config    = get_args()
    REGION    = config['region']
    WORKGROUP = config['workgroup']
    DATABASE  = config['database']
    TABLE     = 'public.music_streams'

    print(f"Starting Glue job | region={REGION} | workgroup={WORKGROUP} | database={DATABASE}")

    # ─── Redshift Data API Client ───────────────────────────────────────────
    client = boto3.client('redshift-data', region_name=REGION)

    def execute_query(sql, description):
        print(f"\n--- {description} ---")
        print(f"SQL: {sql.strip()}")
        try:
            response = client.execute_statement(
                WorkgroupName=WORKGROUP,
                Database=DATABASE,
                Sql=sql
            )
            query_id = response['Id']
            print(f"Query ID: {query_id} — waiting for completion...")

            # Poll until the query finishes
            while True:
                desc   = client.describe_statement(Id=query_id)
                status = desc['Status']
                if status in ('FAILED', 'ABORTED'):
                    raise Exception(f"Query {status}: {desc.get('Error')}")
                elif status == 'FINISHED':
                    print(f"Query finished successfully.")
                    break
                else:
                    time.sleep(1)
        except Exception as e:
            print(f"ERROR during '{description}': {e}")
            raise

    # ─── 1. Create table if it doesn't exist ────────────────────────────────
    execute_query(f"""
        CREATE TABLE IF NOT EXISTS {TABLE} (
            user_id          VARCHAR(50),
            artist_name      VARCHAR(100),
            track_name       VARCHAR(100),
            stream_timestamp VARCHAR(50),
            duration_seconds INT
        );
    """, "Create table (if not exists)")

    # ─── 2. Insert one row ──────────────────────────────────────────────────
    row = {
        'user_id':          'user_01',
        'artist_name':      'The Midnight',
        'track_name':       'Sunset',
        'stream_timestamp': datetime.datetime.now().strftime('%Y-%m-%d %H:%M:%S'),
        'duration_seconds': 245,
    }

    execute_query(f"""
        INSERT INTO {TABLE} (user_id, artist_name, track_name, stream_timestamp, duration_seconds)
        VALUES (
            '{row['user_id']}',
            '{row['artist_name']}',
            '{row['track_name']}',
            '{row['stream_timestamp']}',
            {row['duration_seconds']}
        );
    """, "Insert row")

    print(f"\nJob complete. Row inserted into {TABLE}.")


if __name__ == '__main__':
    run_glue_job()
