"""
Cloud Function: stop-database-if-running 
Triggered hourly by Cloud Scheduler.
"""

import os

import functions_framework
import google.auth
from googleapiclient import discovery

PROJECT_ID = os.environ.get("PROJECT_ID", "lateral-shore-485121-i1")
INSTANCE_NAME = os.environ.get("INSTANCE_NAME", "hw5-mysql")


@functions_framework.http
def stop_database_if_running(request): 
    credentials, _ = google.auth.default()
    service = discovery.build("sqladmin", "v1beta4", credentials=credentials, cache_discovery=False)

    try:
        instance = service.instances().get(project=PROJECT_ID, instance=INSTANCE_NAME).execute()
    except Exception as exc:
        msg = f"Could not fetch Cloud SQL instance info: {exc}"
        print(msg)
        return msg, 500

    state = instance.get("state", "UNKNOWN")
    policy = instance.get("settings", {}).get("activationPolicy", "UNKNOWN")
    print(f"Instance '{INSTANCE_NAME}': state={state}, activationPolicy={policy}")

    if state == "RUNNABLE" and policy == "ALWAYS":
        try:
            op = service.instances().patch(
                project=PROJECT_ID,
                instance=INSTANCE_NAME,
                body={"settings": {"activationPolicy": "NEVER"}},
            ).execute()
            msg = f"Stopped Cloud SQL instance '{INSTANCE_NAME}'. Operation: {op.get('name', 'unknown')}"
            print(msg)
            return msg, 200
        except Exception as exc:
            msg = f"Failed to stop Cloud SQL instance: {exc}"
            print(msg)
            return msg, 500

    msg = f"No action needed for '{INSTANCE_NAME}' (state={state}, policy={policy})."
    print(msg)
    return msg, 200
