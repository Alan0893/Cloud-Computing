#!/bin/bash

set -euo pipefail

PROJECT_ID="$(gcloud config get-value project)"
REGION="${REGION:-us-west1}"
ZONE_A="${ZONE_A:-us-west1-a}"
ZONE_B="${ZONE_B:-us-west1-b}"
RES_SUFFIX="${RES_SUFFIX:-${REGION}}"
BUCKET_NAME="${BUCKET_NAME:-alan-assign2}"

WEBSERVER_SA="hw8-webserver-sa@${PROJECT_ID}.iam.gserviceaccount.com"
REPORTER_SA="hw8-reporter-sa@${PROJECT_ID}.iam.gserviceaccount.com"

SERVER_A_VM="${SERVER_A_VM:-hw8-web-a-${RES_SUFFIX}}"
SERVER_B_VM="${SERVER_B_VM:-hw8-web-b-${RES_SUFFIX}}"
REPORTER_VM="${REPORTER_VM:-hw8-reporter-${RES_SUFFIX}}"

TOPIC_ID="${TOPIC_ID:-hw8-forbidden}"
SUBSCRIPTION_ID="${SUBSCRIPTION_ID:-hw8-forbidden-sub}"

LB_IP_NAME="${LB_IP_NAME:-hw8-lb-ip-${RES_SUFFIX}}"
HC_NAME="${HC_NAME:-hw8-web-hc-${RES_SUFFIX}}"
BACKEND_SERVICE_NAME="${BACKEND_SERVICE_NAME:-hw8-web-bs-${RES_SUFFIX}}"
FORWARDING_RULE_NAME="${FORWARDING_RULE_NAME:-hw8-web-fr-${RES_SUFFIX}}"
INSTANCE_GROUP_A="${INSTANCE_GROUP_A:-hw8-web-ig-a-${RES_SUFFIX}}"
INSTANCE_GROUP_B="${INSTANCE_GROUP_B:-hw8-web-ig-b-${RES_SUFFIX}}"

HTTP_RULE_NAME="${HTTP_RULE_NAME:-allow-hw8-http-80}"
REPORTER_RULE_NAME="${REPORTER_RULE_NAME:-allow-hw8-internal-8080}"
HEALTH_CHECK_RULE_NAME="${HEALTH_CHECK_RULE_NAME:-allow-hw8-health-checks}"

log() { echo "[$(date '+%H:%M:%S')] $*"; }

log "Deleting forwarding rule"
if gcloud compute forwarding-rules describe "$FORWARDING_RULE_NAME" --region="$REGION" --project="$PROJECT_ID" &>/dev/null; then
    gcloud compute forwarding-rules delete "$FORWARDING_RULE_NAME" \
        --region="$REGION" \
        --project="$PROJECT_ID" \
        --quiet
fi

log "Deleting backend service"
if gcloud compute backend-services describe "$BACKEND_SERVICE_NAME" --region="$REGION" --project="$PROJECT_ID" &>/dev/null; then
    gcloud compute backend-services delete "$BACKEND_SERVICE_NAME" \
        --region="$REGION" \
        --project="$PROJECT_ID" \
        --quiet
fi

log "Deleting health check"
if gcloud compute health-checks describe "$HC_NAME" --region="$REGION" --project="$PROJECT_ID" &>/dev/null; then
    gcloud compute health-checks delete "$HC_NAME" \
        --region="$REGION" \
        --project="$PROJECT_ID" \
        --quiet
fi

for GROUP_AND_ZONE in "${INSTANCE_GROUP_A}:${ZONE_A}" "${INSTANCE_GROUP_B}:${ZONE_B}"; do
    GROUP="${GROUP_AND_ZONE%%:*}"
    ZONE="${GROUP_AND_ZONE##*:}"
    log "Deleting instance group ${GROUP}"
    if gcloud compute instance-groups unmanaged describe "$GROUP" --zone="$ZONE" --project="$PROJECT_ID" &>/dev/null; then
        gcloud compute instance-groups unmanaged delete "$GROUP" \
            --zone="$ZONE" \
            --project="$PROJECT_ID" \
            --quiet
    fi
done

for VM_AND_ZONE in "${SERVER_A_VM}:${ZONE_A}" "${SERVER_B_VM}:${ZONE_B}" "${REPORTER_VM}:${ZONE_A}"; do
    VM="${VM_AND_ZONE%%:*}"
    ZONE="${VM_AND_ZONE##*:}"
    log "Deleting VM ${VM}"
    if gcloud compute instances describe "$VM" --zone="$ZONE" --project="$PROJECT_ID" &>/dev/null; then
        gcloud compute instances delete "$VM" \
            --zone="$ZONE" \
            --project="$PROJECT_ID" \
            --quiet
    fi
done

log "Deleting load balancer IP"
if gcloud compute addresses describe "$LB_IP_NAME" --region="$REGION" --project="$PROJECT_ID" &>/dev/null; then
    gcloud compute addresses delete "$LB_IP_NAME" \
        --region="$REGION" \
        --project="$PROJECT_ID" \
        --quiet
fi

for RULE in "$HTTP_RULE_NAME" "$REPORTER_RULE_NAME" "$HEALTH_CHECK_RULE_NAME"; do
    log "Deleting firewall rule ${RULE}"
    if gcloud compute firewall-rules describe "$RULE" --project="$PROJECT_ID" &>/dev/null; then
        gcloud compute firewall-rules delete "$RULE" \
            --project="$PROJECT_ID" \
            --quiet
    fi
done

log "Deleting Pub/Sub resources"
if gcloud pubsub subscriptions describe "$SUBSCRIPTION_ID" --project="$PROJECT_ID" &>/dev/null; then
    gcloud pubsub subscriptions delete "$SUBSCRIPTION_ID" --project="$PROJECT_ID"
fi
if gcloud pubsub topics describe "$TOPIC_ID" --project="$PROJECT_ID" &>/dev/null; then
    gcloud pubsub topics delete "$TOPIC_ID" --project="$PROJECT_ID"
fi

log "Removing IAM bindings"
for ROLE in roles/storage.objectViewer roles/pubsub.publisher roles/logging.logWriter; do
    gcloud projects remove-iam-policy-binding "$PROJECT_ID" \
        --member="serviceAccount:${WEBSERVER_SA}" \
        --role="$ROLE" \
        --quiet 2>/dev/null || true
done
for ROLE in roles/storage.objectViewer roles/pubsub.subscriber; do
    gcloud projects remove-iam-policy-binding "$PROJECT_ID" \
        --member="serviceAccount:${REPORTER_SA}" \
        --role="$ROLE" \
        --quiet 2>/dev/null || true
done

log "Deleting service accounts"
if gcloud iam service-accounts describe "$WEBSERVER_SA" --project="$PROJECT_ID" &>/dev/null; then
    gcloud iam service-accounts delete "$WEBSERVER_SA" --project="$PROJECT_ID" --quiet
fi
if gcloud iam service-accounts describe "$REPORTER_SA" --project="$PROJECT_ID" &>/dev/null; then
    gcloud iam service-accounts delete "$REPORTER_SA" --project="$PROJECT_ID" --quiet
fi

log "Removing uploaded hw8 objects from gs://${BUCKET_NAME}/hw8"
gsutil -m rm -r "gs://${BUCKET_NAME}/hw8" >/dev/null 2>&1 || true
