import os
from google.cloud import pubsub_v1, storage
from google.oauth2 import service_account

PROJECT_ID = "lateral-shore-485121-i1"
SUBSCRIPTION_ID = "forbidden-sub"
BUCKET_NAME = "alan-assign2"
KEY_PATH = os.path.join(os.path.dirname(__file__), "service-account-key.json")

creds = service_account.Credentials.from_service_account_file(
    KEY_PATH,
    scopes=["https://www.googleapis.com/auth/cloud-platform"],
)

subscriber = pubsub_v1.SubscriberClient(credentials=creds)
storage_client = storage.Client(credentials=creds, project=PROJECT_ID)
subscription_path = subscriber.subscription_path(PROJECT_ID, SUBSCRIPTION_ID)

def callback(message):
    error_text = message.data.decode("utf-8")
    print(f"Service 2 Received: {error_text}") 
    
    bucket = storage_client.bucket(BUCKET_NAME)
    blob = bucket.blob("logs/forbidden_access.txt")
    
    current_logs = ""
    if blob.exists():
        current_logs = blob.download_as_text()
    
    new_logs = current_logs + error_text + "\n"
    blob.upload_from_string(new_logs)
    
    message.ack()

print(f"Listening for messages on {subscription_path}...")
streaming_pull_future = subscriber.subscribe(subscription_path, callback=callback)

try:
    streaming_pull_future.result()
except KeyboardInterrupt:
    streaming_pull_future.cancel()