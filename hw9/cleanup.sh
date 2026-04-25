#!/bin/bash
# cleanup.sh - tear down all HW9 infrastructure.

set -uo pipefail

PROJECT_ID="$(gcloud config get-value project)"
REGION="${REGION:-us-west1}"
ZONE="${ZONE:-us-west1-a}"

BUCKET_NAME="${BUCKET_NAME:-alan-assign2}"

CLUSTER_NAME="${CLUSTER_NAME:-hw9-cluster}"
REPO_NAME="${REPO_NAME:-hw9-images}"
IMAGE_NAME="${IMAGE_NAME:-hw9-webserver}"

WEBSERVER_GSA="hw9-webserver-sa@${PROJECT_ID}.iam.gserviceaccount.com"
REPORTER_GSA="hw9-reporter-sa@${PROJECT_ID}.iam.gserviceaccount.com"

TOPIC_ID="${TOPIC_ID:-hw9-forbidden}"
SUBSCRIPTION_ID="${SUBSCRIPTION_ID:-hw9-forbidden-sub}"

REPORTER_VM="${REPORTER_VM:-hw9-reporter}"
CLIENT_VM="${CLIENT_VM:-hw9-client}"

log() { echo "[$(date '+%H:%M:%S')] $*"; }

# --------------------------------------------------------------------------
# 1. Delete K8s resources (Service first so the LB is released cleanly).
# --------------------------------------------------------------------------
if gcloud container clusters describe "$CLUSTER_NAME" \
        --region="$REGION" --project="$PROJECT_ID" &>/dev/null; then
    log "Fetching cluster credentials"
    gcloud container clusters get-credentials "$CLUSTER_NAME" \
        --region="$REGION" --project="$PROJECT_ID" || true

    log "Deleting Kubernetes Service hw9-webserver (releases LB IP)"
    kubectl delete svc hw9-webserver --ignore-not-found=true --wait=true || true

    log "Deleting Kubernetes Deployment hw9-webserver"
    kubectl delete deployment hw9-webserver --ignore-not-found=true || true

    log "Deleting Kubernetes ServiceAccount hw9-webserver-ksa"
    kubectl delete serviceaccount hw9-webserver-ksa --ignore-not-found=true || true

    # Give the LB controller a moment to delete forwarding rules.
    sleep 20

    log "Deleting GKE cluster ${CLUSTER_NAME} (this can take several minutes)"
    gcloud container clusters delete "$CLUSTER_NAME" \
        --region="$REGION" --project="$PROJECT_ID" --quiet || true
fi

# --------------------------------------------------------------------------
# 2. Delete VMs
# --------------------------------------------------------------------------
for VM in "$REPORTER_VM" "$CLIENT_VM"; do
    log "Deleting VM ${VM}"
    if gcloud compute instances describe "$VM" --zone="$ZONE" --project="$PROJECT_ID" &>/dev/null; then
        gcloud compute instances delete "$VM" --zone="$ZONE" --project="$PROJECT_ID" --quiet
    fi
done

# --------------------------------------------------------------------------
# 3. Pub/Sub
# --------------------------------------------------------------------------
log "Deleting Pub/Sub subscription ${SUBSCRIPTION_ID}"
if gcloud pubsub subscriptions describe "$SUBSCRIPTION_ID" --project="$PROJECT_ID" &>/dev/null; then
    gcloud pubsub subscriptions delete "$SUBSCRIPTION_ID" --project="$PROJECT_ID" --quiet
fi
log "Deleting Pub/Sub topic ${TOPIC_ID}"
if gcloud pubsub topics describe "$TOPIC_ID" --project="$PROJECT_ID" &>/dev/null; then
    gcloud pubsub topics delete "$TOPIC_ID" --project="$PROJECT_ID" --quiet
fi

# --------------------------------------------------------------------------
# 4. Artifact Registry
# --------------------------------------------------------------------------
log "Deleting Artifact Registry repo ${REPO_NAME}"
if gcloud artifacts repositories describe "$REPO_NAME" \
        --location="$REGION" --project="$PROJECT_ID" &>/dev/null; then
    gcloud artifacts repositories delete "$REPO_NAME" \
        --location="$REGION" --project="$PROJECT_ID" --quiet
fi

# --------------------------------------------------------------------------
# 5. IAM bindings + service accounts
# --------------------------------------------------------------------------
log "Removing IAM bindings for ${WEBSERVER_GSA}"
for ROLE in roles/storage.objectViewer roles/pubsub.publisher roles/logging.logWriter; do
    gcloud projects remove-iam-policy-binding "$PROJECT_ID" \
        --member="serviceAccount:${WEBSERVER_GSA}" \
        --role="$ROLE" --quiet 2>/dev/null || true
done
log "Removing IAM bindings for ${REPORTER_GSA}"
for ROLE in roles/storage.objectViewer roles/pubsub.subscriber roles/logging.logWriter; do
    gcloud projects remove-iam-policy-binding "$PROJECT_ID" \
        --member="serviceAccount:${REPORTER_GSA}" \
        --role="$ROLE" --quiet 2>/dev/null || true
done

log "Deleting service accounts"
for SA in "$WEBSERVER_GSA" "$REPORTER_GSA"; do
    if gcloud iam service-accounts describe "$SA" --project="$PROJECT_ID" &>/dev/null; then
        gcloud iam service-accounts delete "$SA" --project="$PROJECT_ID" --quiet
    fi
done

# --------------------------------------------------------------------------
# 6. Bucket cleanup (only the hw9 prefix; preserve other homework data).
# --------------------------------------------------------------------------
log "Removing uploaded HW9 objects from gs://${BUCKET_NAME}/hw9"
gsutil -m rm -r "gs://${BUCKET_NAME}/hw9" >/dev/null 2>&1 || true

log ""
log "=========================================="
log "  HW9 infrastructure torn down"
log "=========================================="
