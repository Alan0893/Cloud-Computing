#!/bin/bash
# cleanup.sh 

set -euo pipefail

PROJECT_ID="lateral-shore-485121-i1"
REGION="${REGION:-us-central1}"
ZONE="${ZONE:-us-central1-a}"

SERVER_VM="${SERVER_VM:-hw5-server}"
REPORTER_VM="${REPORTER_VM:-hw5-reporter}"
SQL_INSTANCE_NAME="${SQL_INSTANCE_NAME:-hw5-db}"
STATIC_IP_NAME="${STATIC_IP_NAME:-hw5-server-ip}"

log() { echo "[$(date '+%H:%M:%S')] $*"; }

gcloud config set project "$PROJECT_ID" --quiet >/dev/null

for VM in "$SERVER_VM" "$REPORTER_VM"; do
  log "Stopping VM: $VM ..."
  if gcloud compute instances describe "$VM" --zone="$ZONE" --project="$PROJECT_ID" &>/dev/null; then
    gcloud compute instances stop "$VM" --zone="$ZONE" --project="$PROJECT_ID" --quiet || true
  fi
done

log "Stopping Cloud SQL instance (activationPolicy=NEVER) ..."
if gcloud sql instances describe "$SQL_INSTANCE_NAME" --project="$PROJECT_ID" &>/dev/null; then
  gcloud sql instances patch "$SQL_INSTANCE_NAME" \
    --project="$PROJECT_ID" \
    --activation-policy=NEVER \
    --quiet || true
fi

log "Releasing static IP: $STATIC_IP_NAME ..."
if gcloud compute addresses describe "$STATIC_IP_NAME" --region="$REGION" --project="$PROJECT_ID" &>/dev/null; then
  gcloud compute addresses delete "$STATIC_IP_NAME" --region="$REGION" --project="$PROJECT_ID" --quiet || true
fi

# Revoke ADC token if present 
if gcloud auth application-default print-access-token >/dev/null 2>&1; then
  log "Revoking application-default credentials ..."
  gcloud auth application-default revoke --quiet || true
fi

log "Cleanup complete."
