#!/bin/bash
# setup.sh 

set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

PROJECT_ID="lateral-shore-485121-i1"
REGION="${REGION:-us-central1}"
ZONE="${ZONE:-us-central1-a}"
BUCKET_NAME="${BUCKET_NAME:-alan-assign2}"

SERVER_VM="${SERVER_VM:-hw5-server}"
REPORTER_VM="${REPORTER_VM:-hw5-reporter}"
SERVER_MACHINE="${SERVER_MACHINE:-e2-standard-2}"
REPORTER_MACHINE="${REPORTER_MACHINE:-e2-micro}"
STATIC_IP_NAME="${STATIC_IP_NAME:-hw5-server-ip}"

TOPIC_ID="${TOPIC_ID:-forbidden}"
SUBSCRIPTION_ID="${SUBSCRIPTION_ID:-forbidden-sub}"

SQL_INSTANCE_NAME="${SQL_INSTANCE_NAME:-hw5-db}"
SQL_TIER="${SQL_TIER:-db-g1-small}"
SQL_REGION="${SQL_REGION:-$REGION}"
SQL_DB_VERSION="${SQL_DB_VERSION:-POSTGRES_15}"
SQL_DB_NAME="${SQL_DB_NAME:-hw5db}"
SQL_DB_USER="${SQL_DB_USER:-hw5user}"
SQL_DB_PASS="${SQL_DB_PASS:-hw5pass}"

WEBSERVER_SA="${WEBSERVER_SA:-webserver-sa@${PROJECT_ID}.iam.gserviceaccount.com}"
REPORTER_SA="${REPORTER_SA:-reporter-sa@${PROJECT_ID}.iam.gserviceaccount.com}"
FUNCTION_SA="${FUNCTION_SA:-db-monitor-sa@${PROJECT_ID}.iam.gserviceaccount.com}"

FUNCTION_NAME="${FUNCTION_NAME:-stop-database-if-running}"
SCHEDULER_JOB_NAME="${SCHEDULER_JOB_NAME:-stop-db-hourly}"

log() { echo "[$(date '+%H:%M:%S')] $*"; }

log "Using hardcoded project: $PROJECT_ID"
gcloud config set project "$PROJECT_ID" --quiet >/dev/null

log "Enabling required APIs ..."
gcloud services enable \
  compute.googleapis.com \
  storage.googleapis.com \
  pubsub.googleapis.com \
  cloudfunctions.googleapis.com \
  cloudscheduler.googleapis.com \
  sqladmin.googleapis.com \
  cloudbuild.googleapis.com \
  iam.googleapis.com \
  run.googleapis.com \
  --project="$PROJECT_ID"

log "Ensuring bucket exists: gs://${BUCKET_NAME}"
if ! gsutil ls "gs://${BUCKET_NAME}" &>/dev/null; then
  gsutil mb -p "$PROJECT_ID" -l "$REGION" "gs://${BUCKET_NAME}"
fi

log "Uploading homework source files ..."
gsutil cp server.py "gs://${BUCKET_NAME}/hw5/server.py"
gsutil cp service2.py "gs://${BUCKET_NAME}/hw5/service2.py"
gsutil cp setup_schema.py "gs://${BUCKET_NAME}/hw5/setup_schema.py"

log "Ensuring service accounts exist ..."
if ! gcloud iam service-accounts describe "$WEBSERVER_SA" --project="$PROJECT_ID" &>/dev/null; then
  gcloud iam service-accounts create webserver-sa --project="$PROJECT_ID" --display-name="HW5 Web Server SA"
fi
if ! gcloud iam service-accounts describe "$REPORTER_SA" --project="$PROJECT_ID" &>/dev/null; then
  gcloud iam service-accounts create reporter-sa --project="$PROJECT_ID" --display-name="HW5 Reporter SA"
fi
if ! gcloud iam service-accounts describe "$FUNCTION_SA" --project="$PROJECT_ID" &>/dev/null; then
  gcloud iam service-accounts create db-monitor-sa --project="$PROJECT_ID" --display-name="HW5 DB Monitor SA"
fi

log "Granting IAM roles ..."
for ROLE in roles/storage.objectViewer roles/pubsub.publisher roles/logging.logWriter roles/cloudsql.client; do
  gcloud projects add-iam-policy-binding "$PROJECT_ID" \
    --member="serviceAccount:${WEBSERVER_SA}" \
    --role="$ROLE" --quiet
done
for ROLE in roles/storage.objectViewer roles/pubsub.subscriber; do
  gcloud projects add-iam-policy-binding "$PROJECT_ID" \
    --member="serviceAccount:${REPORTER_SA}" \
    --role="$ROLE" --quiet
done
gcloud projects add-iam-policy-binding "$PROJECT_ID" \
  --member="serviceAccount:${FUNCTION_SA}" \
  --role="roles/cloudsql.admin" \
  --quiet

log "Ensuring Pub/Sub resources exist ..."
if ! gcloud pubsub topics describe "$TOPIC_ID" --project="$PROJECT_ID" &>/dev/null; then
  gcloud pubsub topics create "$TOPIC_ID" --project="$PROJECT_ID"
fi
if ! gcloud pubsub subscriptions describe "$SUBSCRIPTION_ID" --project="$PROJECT_ID" &>/dev/null; then
  gcloud pubsub subscriptions create "$SUBSCRIPTION_ID" --topic="$TOPIC_ID" --project="$PROJECT_ID"
fi

DB_CREATED=0
log "Ensuring Cloud SQL instance exists ..."
if ! gcloud sql instances describe "$SQL_INSTANCE_NAME" --project="$PROJECT_ID" &>/dev/null; then
  gcloud sql instances create "$SQL_INSTANCE_NAME" \
    --project="$PROJECT_ID" \
    --database-version="$SQL_DB_VERSION" \
    --tier="$SQL_TIER" \
    --region="$SQL_REGION" \
    --availability-type=zonal \
    --storage-type=SSD \
    --storage-size=10
  DB_CREATED=1
fi

log "Starting Cloud SQL instance (activationPolicy=ALWAYS) ..."
gcloud sql instances patch "$SQL_INSTANCE_NAME" --project="$PROJECT_ID" --activation-policy=ALWAYS --quiet

if ! gcloud sql databases describe "$SQL_DB_NAME" --instance="$SQL_INSTANCE_NAME" --project="$PROJECT_ID" &>/dev/null; then
  gcloud sql databases create "$SQL_DB_NAME" --instance="$SQL_INSTANCE_NAME" --project="$PROJECT_ID"
  DB_CREATED=1
fi

if ! gcloud sql users list --instance="$SQL_INSTANCE_NAME" --project="$PROJECT_ID" --format="value(name)" | grep -x "$SQL_DB_USER" >/dev/null 2>&1; then
  gcloud sql users create "$SQL_DB_USER" --instance="$SQL_INSTANCE_NAME" --password="$SQL_DB_PASS" --project="$PROJECT_ID"
else
  gcloud sql users set-password "$SQL_DB_USER" --instance="$SQL_INSTANCE_NAME" --password="$SQL_DB_PASS" --project="$PROJECT_ID"
fi

DB_CONN_NAME="$(gcloud sql instances describe "$SQL_INSTANCE_NAME" --project="$PROJECT_ID" --format='value(connectionName)')"

log "Ensuring static IP and firewall rules exist ..."
if ! gcloud compute addresses describe "$STATIC_IP_NAME" --region="$REGION" --project="$PROJECT_ID" &>/dev/null; then
  gcloud compute addresses create "$STATIC_IP_NAME" --region="$REGION" --project="$PROJECT_ID"
fi
SERVER_IP="$(gcloud compute addresses describe "$STATIC_IP_NAME" --region="$REGION" --project="$PROJECT_ID" --format='value(address)')"

if ! gcloud compute firewall-rules describe allow-http-80 --project="$PROJECT_ID" &>/dev/null; then
  gcloud compute firewall-rules create allow-http-80 \
    --project="$PROJECT_ID" \
    --direction=INGRESS --priority=1000 --network=default --action=ALLOW \
    --rules=tcp:80 --target-tags=http-server --quiet
fi
if ! gcloud compute firewall-rules describe allow-internal-8080 --project="$PROJECT_ID" &>/dev/null; then
  gcloud compute firewall-rules create allow-internal-8080 \
    --project="$PROJECT_ID" \
    --direction=INGRESS --priority=1000 --network=default --action=ALLOW \
    --rules=tcp:8080 --source-ranges=10.0.0.0/8 --target-tags=reporter --quiet
fi

log "Ensuring reporter VM exists ..."
if ! gcloud compute instances describe "$REPORTER_VM" --zone="$ZONE" --project="$PROJECT_ID" &>/dev/null; then
  gcloud compute instances create "$REPORTER_VM" \
    --project="$PROJECT_ID" \
    --zone="$ZONE" \
    --machine-type="$REPORTER_MACHINE" \
    --image-family=debian-12 \
    --image-project=debian-cloud \
    --service-account="$REPORTER_SA" \
    --scopes=cloud-platform \
    --tags=reporter \
    --metadata="bucket-name=${BUCKET_NAME}" \
    --metadata-from-file startup-script=service2_startup.sh \
    --quiet
fi

REPORTER_INTERNAL_IP="$(gcloud compute instances describe "$REPORTER_VM" --zone="$ZONE" --project="$PROJECT_ID" --format='value(networkInterfaces[0].networkIP)')"
SERVICE2_URL="http://${REPORTER_INTERNAL_IP}:8080"

log "Ensuring web server VM exists ..."
if ! gcloud compute instances describe "$SERVER_VM" --zone="$ZONE" --project="$PROJECT_ID" &>/dev/null; then
  gcloud compute instances create "$SERVER_VM" \
    --project="$PROJECT_ID" \
    --zone="$ZONE" \
    --machine-type="$SERVER_MACHINE" \
    --image-family=debian-12 \
    --image-project=debian-cloud \
    --service-account="$WEBSERVER_SA" \
    --scopes=cloud-platform \
    --tags=http-server,webserver \
    --address="$STATIC_IP_NAME" \
    --metadata="service2-url=${SERVICE2_URL},bucket-name=${BUCKET_NAME},db-user=${SQL_DB_USER},db-pass=${SQL_DB_PASS},db-name=${SQL_DB_NAME},db-conn-name=${DB_CONN_NAME}" \
    --metadata-from-file startup-script=startup.sh \
    --quiet
fi

if [ "$DB_CREATED" -eq 1 ]; then
  log "Cloud SQL was newly created; schema setup script will run during VM startup."
else
  log "Cloud SQL already existed; startup still validates schema idempotently."
fi

log "Deploying cloud function ..."
gcloud functions deploy "$FUNCTION_NAME" \
  --project="$PROJECT_ID" \
  --region="$REGION" \
  --gen2 \
  --runtime=python312 \
  --source=cloud_function \
  --entry-point=stop_database_if_running \
  --trigger-http \
  --service-account="$FUNCTION_SA" \
  --set-env-vars="PROJECT_ID=${PROJECT_ID},INSTANCE_NAME=${SQL_INSTANCE_NAME}" \
  --no-allow-unauthenticated \
  --quiet

FUNCTION_URL="$(gcloud functions describe "$FUNCTION_NAME" --project="$PROJECT_ID" --region="$REGION" --gen2 --format='value(serviceConfig.uri)')"
PROJECT_NUMBER="$(gcloud projects describe "$PROJECT_ID" --format='value(projectNumber)')"
CLOUD_SCHEDULER_AGENT="service-${PROJECT_NUMBER}@gcp-sa-cloudscheduler.iam.gserviceaccount.com"

gcloud iam service-accounts add-iam-policy-binding "$FUNCTION_SA" \
  --project="$PROJECT_ID" \
  --member="serviceAccount:${CLOUD_SCHEDULER_AGENT}" \
  --role="roles/iam.serviceAccountTokenCreator" \
  --quiet

gcloud run services add-iam-policy-binding "$FUNCTION_NAME" \
  --project="$PROJECT_ID" \
  --region="$REGION" \
  --member="serviceAccount:${FUNCTION_SA}" \
  --role="roles/run.invoker" \
  --quiet

if ! gcloud scheduler jobs describe "$SCHEDULER_JOB_NAME" --location="$REGION" --project="$PROJECT_ID" &>/dev/null; then
  gcloud scheduler jobs create http "$SCHEDULER_JOB_NAME" \
    --project="$PROJECT_ID" \
    --location="$REGION" \
    --schedule="0 * * * *" \
    --http-method=GET \
    --uri="$FUNCTION_URL" \
    --oidc-service-account-email="$FUNCTION_SA" \
    --oidc-token-audience="$FUNCTION_URL" \
    --quiet
else
  gcloud scheduler jobs update http "$SCHEDULER_JOB_NAME" \
    --project="$PROJECT_ID" \
    --location="$REGION" \
    --schedule="0 * * * *" \
    --http-method=GET \
    --uri="$FUNCTION_URL" \
    --oidc-service-account-email="$FUNCTION_SA" \
    --oidc-token-audience="$FUNCTION_URL" \
    --quiet
fi

# Ensure scheduler is enabled after creation/update.
gcloud scheduler jobs resume "$SCHEDULER_JOB_NAME" \
  --project="$PROJECT_ID" \
  --location="$REGION" \
  --quiet || true

log "Setup complete."
log "Web server URL: http://${SERVER_IP}"
log "Reporter URL (internal): ${SERVICE2_URL}"
log "Cloud SQL instance: ${SQL_INSTANCE_NAME}"
