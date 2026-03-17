#!/bin/bash
# setup.sh - Provision all infrastructure for HW4

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

SERVER_MACHINE="e2-micro"
CLIENT_MACHINE="e2-medium"
REPORTER_MACHINE="e2-micro"

log() { echo "[$(date '+%H:%M:%S')] $*"; }

# ---------------------------------------------------------------------------
# GCS bucket
# ---------------------------------------------------------------------------
log "Creating GCS bucket gs://$BUCKET_NAME ..."
if ! gsutil ls "gs://${BUCKET_NAME}" &>/dev/null; then
    gsutil mb -p "$PROJECT_ID" -l "$REGION" "gs://${BUCKET_NAME}"
fi

log "Uploading application files to gs://$BUCKET_NAME/ ..."
gsutil cp server.py   "gs://${BUCKET_NAME}/server.py"
gsutil cp service2.py "gs://${BUCKET_NAME}/service2.py"

# ---------------------------------------------------------------------------
# Service accounts
# ---------------------------------------------------------------------------
log "Creating service account: webserver-sa ..."
if ! gcloud iam service-accounts describe "$WEBSERVER_SA" --project="$PROJECT_ID" &>/dev/null; then
    gcloud iam service-accounts create webserver-sa \
        --display-name="HW4 Web Server SA" \
        --project="$PROJECT_ID"
fi

log "Creating service account: reporter-sa ..."
if ! gcloud iam service-accounts describe "$REPORTER_SA" --project="$PROJECT_ID" &>/dev/null; then
    gcloud iam service-accounts create reporter-sa \
        --display-name="HW4 Reporter SA" \
        --project="$PROJECT_ID"
fi

log "Assigning IAM roles to webserver-sa ..."
for ROLE in roles/storage.objectViewer roles/pubsub.publisher roles/logging.logWriter; do
    gcloud projects add-iam-policy-binding "$PROJECT_ID" \
        --member="serviceAccount:${WEBSERVER_SA}" \
        --role="$ROLE" --quiet
done

log "Assigning IAM roles to reporter-sa ..."
for ROLE in roles/storage.objectViewer roles/pubsub.subscriber; do
    gcloud projects add-iam-policy-binding "$PROJECT_ID" \
        --member="serviceAccount:${REPORTER_SA}" \
        --role="$ROLE" --quiet
done

# ---------------------------------------------------------------------------
# Pub/Sub topic and subscription
# ---------------------------------------------------------------------------
log "Creating Pub/Sub topic: $TOPIC_ID ..."
if ! gcloud pubsub topics describe "$TOPIC_ID" --project="$PROJECT_ID" &>/dev/null; then
    gcloud pubsub topics create "$TOPIC_ID" --project="$PROJECT_ID"
fi

log "Creating Pub/Sub subscription: $SUBSCRIPTION_ID ..."
if ! gcloud pubsub subscriptions describe "$SUBSCRIPTION_ID" --project="$PROJECT_ID" &>/dev/null; then
    gcloud pubsub subscriptions create "$SUBSCRIPTION_ID" \
        --topic="$TOPIC_ID" \
        --project="$PROJECT_ID"
fi

# ---------------------------------------------------------------------------
# Static external IP for the web server
# ---------------------------------------------------------------------------
log "Reserving static IP '$STATIC_IP_NAME' in region $REGION ..."
if ! gcloud compute addresses describe "$STATIC_IP_NAME" --region="$REGION" --project="$PROJECT_ID" &>/dev/null; then
    gcloud compute addresses create "$STATIC_IP_NAME" \
        --region="$REGION" \
        --project="$PROJECT_ID"
fi
SERVER_IP=$(gcloud compute addresses describe "$STATIC_IP_NAME" \
    --region="$REGION" \
    --project="$PROJECT_ID" \
    --format="value(address)")
log "Static IP: $SERVER_IP"

# ---------------------------------------------------------------------------
# Firewall rules
# ---------------------------------------------------------------------------
log "Ensuring firewall rule allows HTTP on port 80 ..."
if ! gcloud compute firewall-rules describe allow-http-80 --project="$PROJECT_ID" &>/dev/null; then
    gcloud compute firewall-rules create allow-http-80 \
        --project="$PROJECT_ID" \
        --direction=INGRESS \
        --priority=1000 \
        --network=default \
        --action=ALLOW \
        --rules=tcp:80 \
        --target-tags=http-server \
        --quiet
fi

log "Ensuring firewall rule allows port 8080 for internal VMs ..."
if ! gcloud compute firewall-rules describe allow-internal-8080 --project="$PROJECT_ID" &>/dev/null; then
    gcloud compute firewall-rules create allow-internal-8080 \
        --project="$PROJECT_ID" \
        --direction=INGRESS \
        --priority=1000 \
        --network=default \
        --action=ALLOW \
        --rules=tcp:8080 \
        --source-ranges=10.0.0.0/8 \
        --target-tags=reporter \
        --quiet
fi

# ---------------------------------------------------------------------------
# VM3 (reporter) - created first to obtain its internal IP for SERVICE2_URL
# ---------------------------------------------------------------------------
log "Creating VM3 ($REPORTER_VM) ..."
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

REPORTER_INTERNAL_IP=$(gcloud compute instances describe "$REPORTER_VM" \
    --zone="$ZONE" \
    --project="$PROJECT_ID" \
    --format="value(networkInterfaces[0].networkIP)")
log "Reporter internal IP: $REPORTER_INTERNAL_IP"
SERVICE2_URL="http://${REPORTER_INTERNAL_IP}:8080"

# ---------------------------------------------------------------------------
# VM1 (web server)
# ---------------------------------------------------------------------------
log "Creating VM1 ($SERVER_VM) with static IP $SERVER_IP ..."
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
        --metadata="service2-url=${SERVICE2_URL},bucket-name=${BUCKET_NAME}" \
        --metadata-from-file startup-script=startup.sh \
        --quiet
fi

# ---------------------------------------------------------------------------
# VM2 (client)
# ---------------------------------------------------------------------------
log "Creating VM2 ($CLIENT_VM) ..."
if ! gcloud compute instances describe "$CLIENT_VM" --zone="$ZONE" --project="$PROJECT_ID" &>/dev/null; then
    gcloud compute instances create "$CLIENT_VM" \
        --project="$PROJECT_ID" \
        --zone="$ZONE" \
        --machine-type="$CLIENT_MACHINE" \
        --image-family=debian-12 \
        --image-project=debian-cloud \
        --scopes=cloud-platform \
        --tags=client \
        --metadata=server-ip="$SERVER_IP" \
        --quiet
fi

log ""
log "=========================================="
log "  All infrastructure provisioned!"
log "=========================================="
log "  Web Server  (VM1): $SERVER_VM   ->  http://$SERVER_IP"
log "  Client      (VM2): $CLIENT_VM"
log "  Reporter    (VM3): $REPORTER_VM  ->  $SERVICE2_URL"
log "=========================================="
