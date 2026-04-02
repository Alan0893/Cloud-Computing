#!/bin/bash
# setup.sh

set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HW6_DIR="$SCRIPT_DIR"

PROJECT_ID="${PROJECT_ID:-lateral-shore-485121-i1}"
REGION="${REGION:-us-central1}"
ZONE="${ZONE:-us-central1-a}"
BUCKET_NAME="${BUCKET_NAME:-alan-assign2}"

SQL_INSTANCE_NAME="${SQL_INSTANCE_NAME:-hw5-db}"
SQL_DB_NAME="${SQL_DB_NAME:-hw5db}"
SQL_DB_USER="${SQL_DB_USER:-hw5user}"
SQL_DB_PASS="${SQL_DB_PASS:-hw5pass}"

VM_NAME="${VM_NAME:-hw6-ml-$(date +%s)}"
VM_MACHINE="${VM_MACHINE:-e2-standard-2}"
VM_SPOT="${VM_SPOT:-false}"
VM_SA="${VM_SA:-webserver-sa@${PROJECT_ID}.iam.gserviceaccount.com}"

REMOTE_DIR="/opt/hw6"
REMOTE_STAGING="~/hw6_staging"
OUTPUT_PREFIX="hw6_outputs"
BUCKET_PREFIX="hw6/model_outputs"

log() { echo "[$(date '+%H:%M:%S')] $*"; }

cleanup() {
  set +e
  log "Cleaning up VM and stopping database..."
  gcloud compute instances delete "$VM_NAME" --zone="$ZONE" --project="$PROJECT_ID" --quiet >/dev/null 2>&1 || true
  gcloud sql instances patch "$SQL_INSTANCE_NAME" --project="$PROJECT_ID" --activation-policy=NEVER --quiet >/dev/null 2>&1 || true
}
trap cleanup EXIT

log "Using project: $PROJECT_ID (hw6 dir: $HW6_DIR)"
gcloud config set project "$PROJECT_ID" --quiet >/dev/null

log "Enabling required APIs (idempotent)..."
gcloud services enable compute.googleapis.com sqladmin.googleapis.com storage.googleapis.com --project="$PROJECT_ID" >/dev/null

log "Ensuring VM service account can write output files to bucket..."
gcloud projects add-iam-policy-binding "$PROJECT_ID" \
  --member="serviceAccount:${VM_SA}" \
  --role="roles/storage.objectAdmin" \
  --quiet >/dev/null
gcloud projects add-iam-policy-binding "$PROJECT_ID" \
  --member="serviceAccount:${VM_SA}" \
  --role="roles/cloudsql.client" \
  --quiet >/dev/null

log "Starting Cloud SQL instance..."
gcloud sql instances patch "$SQL_INSTANCE_NAME" --project="$PROJECT_ID" --activation-policy=ALWAYS --quiet >/dev/null
log "Waiting for Cloud SQL to be RUNNABLE..."
for i in $(seq 1 40); do
  STATE=$(gcloud sql instances describe "$SQL_INSTANCE_NAME" --project="$PROJECT_ID" --format='value(state)' 2>/dev/null || echo "UNKNOWN")
  log "  DB state: $STATE (attempt $i/40)"
  [ "$STATE" = "RUNNABLE" ] && break
  sleep 10
done
DB_CONN_NAME="$(gcloud sql instances describe "$SQL_INSTANCE_NAME" --project="$PROJECT_ID" --format='value(connectionName)')"

log "Creating VM: $VM_NAME"
SPOT_FLAGS=""
[ "$VM_SPOT" = "true" ] && SPOT_FLAGS="--provisioning-model=SPOT --instance-termination-action=DELETE"
gcloud compute instances create "$VM_NAME" \
  --project="$PROJECT_ID" \
  --zone="$ZONE" \
  --machine-type="$VM_MACHINE" \
  --image-family=debian-12 \
  --image-project=debian-cloud \
  --service-account="$VM_SA" \
  --scopes=cloud-platform \
  $SPOT_FLAGS \
  --quiet >/dev/null

log "Waiting for VM SSH to become available..."
for i in $(seq 1 30); do
  gcloud compute ssh "$VM_NAME" --zone="$ZONE" --project="$PROJECT_ID" \
    --command "echo ready" >/dev/null 2>&1 && break || true
  sleep 6
done

log "Preparing VM staging directory..."
gcloud compute ssh "$VM_NAME" --zone="$ZONE" --project="$PROJECT_ID" --command "mkdir -p ${REMOTE_STAGING}" >/dev/null

log "Copying HW6 files to VM..."
gcloud compute scp \
  "${HW6_DIR}/requirements.txt" \
  "${HW6_DIR}/schema_3nf.sql" \
  "${HW6_DIR}/migrate_to_3nf.sql" \
  "${HW6_DIR}/normalize_schema.py" \
  "${HW6_DIR}/train_models.py" \
  "${VM_NAME}:${REMOTE_STAGING}/" \
  --zone="$ZONE" \
  --project="$PROJECT_ID" >/dev/null

log "Running normalization + model training on VM..."
gcloud compute ssh "$VM_NAME" --zone="$ZONE" --project="$PROJECT_ID" --command "
  set -euo pipefail
  sudo mkdir -p '${REMOTE_DIR}'
  sudo chown \"\$USER\":\"\$USER\" '${REMOTE_DIR}'
  cp -f ${REMOTE_STAGING}/* '${REMOTE_DIR}/'
  cd '${REMOTE_DIR}'
  sudo apt-get update -y >/dev/null
  sudo apt-get install -y python3 python3-pip python3-venv curl >/dev/null
  python3 -m venv venv
  source venv/bin/activate
  pip install --upgrade pip >/dev/null
  pip install -r requirements.txt >/dev/null
  curl -fsSL -o cloud-sql-proxy 'https://storage.googleapis.com/cloud-sql-connectors/cloud-sql-proxy/v2.14.3/cloud-sql-proxy.linux.amd64'
  chmod +x cloud-sql-proxy
  ./cloud-sql-proxy --address 127.0.0.1 --port 5432 '${DB_CONN_NAME}' > proxy.log 2>&1 &
  PROXY_PID=\$!
  for _w in \$(seq 1 20); do sleep 2; grep -q 'Listening' proxy.log 2>/dev/null && break || true; done
  export DATABASE_URL='postgresql+pg8000://${SQL_DB_USER}:${SQL_DB_PASS}@127.0.0.1:5432/${SQL_DB_NAME}'
  export BUCKET_NAME='${BUCKET_NAME}'
  export PROJECT_ID='${PROJECT_ID}'
  export GOOGLE_CLOUD_PROJECT='${PROJECT_ID}'
  python normalize_schema.py
  python train_models.py --database-url \"\$DATABASE_URL\" --bucket-name \"\$BUCKET_NAME\" --output-prefix '${OUTPUT_PREFIX}' --bucket-prefix '${BUCKET_PREFIX}'
  kill \"\$PROXY_PID\" || true
"

log "Printing uploaded model outputs from bucket..."
gsutil cat "gs://${BUCKET_NAME}/${BUCKET_PREFIX}/${OUTPUT_PREFIX}_metrics.txt"
gsutil cat "gs://${BUCKET_NAME}/${BUCKET_PREFIX}/${OUTPUT_PREFIX}_country_test_predictions.csv"
gsutil cat "gs://${BUCKET_NAME}/${BUCKET_PREFIX}/${OUTPUT_PREFIX}_income_test_predictions.csv"

log "HW6 setup complete."
