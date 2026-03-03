#!/bin/bash
# cleanup.sh - Tear down all infrastructure for HW4

set -e

PROJECT_ID=$(gcloud config get-value project)
REGION="${REGION:-us-central1}"
ZONE="${ZONE:-us-central1-a}"
BUCKET_NAME="${BUCKET_NAME:-alan-assign2}"

WEBSERVER_SA="webserver-sa@${PROJECT_ID}.iam.gserviceaccount.com"
REPORTER_SA="reporter-sa@${PROJECT_ID}.iam.gserviceaccount.com"

SERVER_VM="hw4-server"
CLIENT_VM="hw4-client"
REPORTER_VM="hw4-reporter"
STATIC_IP_NAME="hw4-server-ip"
TOPIC_ID="forbidden"
SUBSCRIPTION_ID="forbidden-sub"

log() { echo "[$(date '+%H:%M:%S')] $*"; }

# ---------------------------------------------------------------------------
# Delete VMs
# ---------------------------------------------------------------------------
for VM in "$SERVER_VM" "$CLIENT_VM" "$REPORTER_VM"; do
    log "Deleting VM: $VM ..."
    if gcloud compute instances describe "$VM" --zone="$ZONE" --project="$PROJECT_ID" &>/dev/null; then
        gcloud compute instances delete "$VM" --zone="$ZONE" --project="$PROJECT_ID" --quiet
    fi
done

# ---------------------------------------------------------------------------
# Release static IP
# ---------------------------------------------------------------------------
log "Releasing static IP '$STATIC_IP_NAME' ..."
if gcloud compute addresses describe "$STATIC_IP_NAME" --region="$REGION" --project="$PROJECT_ID" &>/dev/null; then
    gcloud compute addresses delete "$STATIC_IP_NAME" --region="$REGION" --project="$PROJECT_ID" --quiet
fi

# ---------------------------------------------------------------------------
# Delete firewall rules
# ---------------------------------------------------------------------------
for RULE in allow-http-80 allow-internal-8080; do
    log "Deleting firewall rule: $RULE ..."
    if gcloud compute firewall-rules describe "$RULE" --project="$PROJECT_ID" &>/dev/null; then
        gcloud compute firewall-rules delete "$RULE" --project="$PROJECT_ID" --quiet
    fi
done

# ---------------------------------------------------------------------------
# Delete Pub/Sub subscription and topic
# ---------------------------------------------------------------------------
log "Deleting Pub/Sub subscription: $SUBSCRIPTION_ID ..."
if gcloud pubsub subscriptions describe "$SUBSCRIPTION_ID" --project="$PROJECT_ID" &>/dev/null; then
    gcloud pubsub subscriptions delete "$SUBSCRIPTION_ID" --project="$PROJECT_ID"
fi

log "Deleting Pub/Sub topic: $TOPIC_ID ..."
if gcloud pubsub topics describe "$TOPIC_ID" --project="$PROJECT_ID" &>/dev/null; then
    gcloud pubsub topics delete "$TOPIC_ID" --project="$PROJECT_ID"
fi

# ---------------------------------------------------------------------------
# Remove IAM bindings and delete service accounts
# ---------------------------------------------------------------------------
log "Removing IAM bindings for webserver-sa ..."
for ROLE in roles/storage.objectViewer roles/pubsub.publisher roles/logging.logWriter; do
    gcloud projects remove-iam-policy-binding "$PROJECT_ID" \
        --member="serviceAccount:${WEBSERVER_SA}" \
        --role="$ROLE" --quiet 2>/dev/null || true
done

log "Removing IAM bindings for reporter-sa ..."
for ROLE in roles/storage.objectViewer roles/pubsub.subscriber; do
    gcloud projects remove-iam-policy-binding "$PROJECT_ID" \
        --member="serviceAccount:${REPORTER_SA}" \
        --role="$ROLE" --quiet 2>/dev/null || true
done

log "Deleting service account: webserver-sa ..."
if gcloud iam service-accounts describe "$WEBSERVER_SA" --project="$PROJECT_ID" &>/dev/null; then
    gcloud iam service-accounts delete "$WEBSERVER_SA" --project="$PROJECT_ID" --quiet
fi

log "Deleting service account: reporter-sa ..."
if gcloud iam service-accounts describe "$REPORTER_SA" --project="$PROJECT_ID" &>/dev/null; then
    gcloud iam service-accounts delete "$REPORTER_SA" --project="$PROJECT_ID" --quiet
fi

# ---------------------------------------------------------------------------
# Delete GCS bucket and all its contents
# ---------------------------------------------------------------------------
log "Deleting GCS bucket gs://$BUCKET_NAME ..."
if gsutil ls "gs://${BUCKET_NAME}" &>/dev/null; then
    gsutil -m rm -r "gs://${BUCKET_NAME}"
fi

log ""
log "=========================================="
log "  All infrastructure torn down!"
log "=========================================="
