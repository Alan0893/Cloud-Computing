#!/bin/bash
# cleanup.sh 

set -euo pipefail

PROJECT_ID="${PROJECT_ID:-lateral-shore-485121-i1}"
REGION="${REGION:-us-central1}"
ZONE="${ZONE:-us-central1-a}"
SQL_INSTANCE_NAME="${SQL_INSTANCE_NAME:-hw5-db}"

log() { echo "[$(date '+%H:%M:%S')] $*"; }

gcloud config set project "$PROJECT_ID" --quiet >/dev/null

log "Deleting Compute Engine VMs matching name ~ '^hw6-ml-' in zone $ZONE ..."
while read -r name; do
  [ -z "$name" ] && continue
  log "Deleting VM: $name ..."
  gcloud compute instances delete "$name" --zone="$ZONE" --project="$PROJECT_ID" --quiet || true
done < <(gcloud compute instances list --project="$PROJECT_ID" --zones="$ZONE" \
  --filter="name~'^hw6-ml-' AND status!=TERMINATED" --format="value(name)" 2>/dev/null || true)

log "Stopping Cloud SQL instance (activationPolicy=NEVER) ..."
if gcloud sql instances describe "$SQL_INSTANCE_NAME" --project="$PROJECT_ID" &>/dev/null; then
  gcloud sql instances patch "$SQL_INSTANCE_NAME" \
    --project="$PROJECT_ID" \
    --activation-policy=NEVER \
    --quiet || true
fi

log "HW6 cleanup complete."
