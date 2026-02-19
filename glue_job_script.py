import boto3
import sys
import datetime
import time

def run_glue_job():
    """
    AWS Glue Job to insert a single row of music streaming data into Redshift Serverless.
    
    Prerequisites:
    1. The Glue Job execution role must have 'redshift-data:ExecuteStatement' permissions.
    2. The Redshift Serverless workgroup 'default' must exist.
    """
    
    # --- Configuration ---
    # Updated based on user feedback to match their environment
    WORKGROUP_NAME = 'default' 
    DATABASE_NAME = 'default-namespace' # Often the database name matches the namespace in Serverless
    TABLE_NAME = 'public.music_streams'
    
    # --- Redshift Data API Client ---
    client = boto3.client('redshift-data')

    def execute_query(sql, description):
        print(f"--- {description} ---")
        print(f"Executing SQL: {sql}")
        try:
            response = client.execute_statement(
                WorkgroupName=WORKGROUP_NAME,
                Database=DATABASE_NAME,
                Sql=sql
            )
            query_id = response['Id']
            print(f"Query started with ID: {query_id}")
            
            # Wait for completion
            while True:
                desc = client.describe_statement(Id=query_id)
                status = desc['Status']
                if status in ['FAILED', 'ABORTED']:
                    err = desc.get('Error')
                    raise Exception(f"Query {status}: {err}")
                elif status == 'FINISHED':
                    print(f"Query {query_id} finished successfully.")
                    break
                else:
                    time.sleep(1) # Simple exponential backoff or constant wait
        except Exception as e:
            print(f"Error during {description}: {str(e)}")
            raise e

    # --- 1. Ensure Table Exists ---
    create_table_sql = f"""
        CREATE TABLE IF NOT EXISTS {TABLE_NAME} (
            user_id VARCHAR(50),
            artist_name VARCHAR(100),
            track_name VARCHAR(100),
            timestamp VARCHAR(50),
            duration_seconds INT
        );
    """
    execute_query(create_table_sql, "Creating Table (if not exists)")

    # --- 2. Generate Dummy Data ---
    data = {
        'user_id': 'user_01',
        'artist_name': 'The Midnight',
        'track_name': 'Sunset',
        'timestamp': datetime.datetime.now().strftime('%Y-%m-%d %H:%M:%S'),
        'duration_seconds': 245
    }
    
    # --- 3. Insert Data ---
    insert_sql = f"""
        INSERT INTO {TABLE_NAME} (user_id, artist_name, track_name, timestamp, duration_seconds)
        VALUES ('{data['user_id']}', '{data['artist_name']}', '{data['track_name']}', '{data['timestamp']}', {data['duration_seconds']});
    """
    execute_query(insert_sql, "Inserting Data")

if __name__ == '__main__':
    run_glue_job()
