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

SERVER_MACHINE="${SERVER_MACHINE:-e2-micro}"
REPORTER_MACHINE="${REPORTER_MACHINE:-e2-micro}"

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

log "Using project: $PROJECT_ID"
log "Uploading HW8 application files to gs://${BUCKET_NAME}/hw8"
if ! gsutil ls "gs://${BUCKET_NAME}" &>/dev/null; then
    gsutil mb -p "$PROJECT_ID" -l "$REGION" "gs://${BUCKET_NAME}"
fi
gsutil cp server.py "gs://${BUCKET_NAME}/hw8/server.py"
gsutil cp service2.py "gs://${BUCKET_NAME}/hw8/service2.py"

log "Ensuring service accounts exist"
CREATED_SA=0
if ! gcloud iam service-accounts describe "$WEBSERVER_SA" --project="$PROJECT_ID" &>/dev/null; then
    gcloud iam service-accounts create hw8-webserver-sa \
        --display-name="HW8 Web Server SA" \
        --project="$PROJECT_ID"
    CREATED_SA=1
fi
if ! gcloud iam service-accounts describe "$REPORTER_SA" --project="$PROJECT_ID" &>/dev/null; then
    gcloud iam service-accounts create hw8-reporter-sa \
        --display-name="HW8 Reporter SA" \
        --project="$PROJECT_ID"
    CREATED_SA=1
fi
if [ "$CREATED_SA" -eq 1 ]; then
    log "Waiting for new service accounts to propagate before IAM bindings"
    sleep "${IAM_PROPAGATION_SLEEP:-20}"
fi

for ROLE in roles/storage.objectViewer roles/pubsub.publisher roles/logging.logWriter; do
    gcloud projects add-iam-policy-binding "$PROJECT_ID" \
        --member="serviceAccount:${WEBSERVER_SA}" \
        --role="$ROLE" \
        --quiet >/dev/null
done
for ROLE in roles/storage.objectViewer roles/pubsub.subscriber; do
    gcloud projects add-iam-policy-binding "$PROJECT_ID" \
        --member="serviceAccount:${REPORTER_SA}" \
        --role="$ROLE" \
        --quiet >/dev/null
done

log "Ensuring Pub/Sub resources exist"
if ! gcloud pubsub topics describe "$TOPIC_ID" --project="$PROJECT_ID" &>/dev/null; then
    gcloud pubsub topics create "$TOPIC_ID" --project="$PROJECT_ID"
fi
if ! gcloud pubsub subscriptions describe "$SUBSCRIPTION_ID" --project="$PROJECT_ID" &>/dev/null; then
    gcloud pubsub subscriptions create "$SUBSCRIPTION_ID" \
        --topic="$TOPIC_ID" \
        --project="$PROJECT_ID"
fi

log "Ensuring firewall rules exist"
if ! gcloud compute firewall-rules describe "$HTTP_RULE_NAME" --project="$PROJECT_ID" &>/dev/null; then
    gcloud compute firewall-rules create "$HTTP_RULE_NAME" \
        --project="$PROJECT_ID" \
        --direction=INGRESS \
        --priority=1000 \
        --network=default \
        --action=ALLOW \
        --rules=tcp:80 \
        --source-ranges=0.0.0.0/0 \
        --target-tags=hw8-webserver \
        --quiet
fi
if ! gcloud compute firewall-rules describe "$REPORTER_RULE_NAME" --project="$PROJECT_ID" &>/dev/null; then
    gcloud compute firewall-rules create "$REPORTER_RULE_NAME" \
        --project="$PROJECT_ID" \
        --direction=INGRESS \
        --priority=1000 \
        --network=default \
        --action=ALLOW \
        --rules=tcp:8080 \
        --source-ranges=10.0.0.0/8 \
        --target-tags=hw8-reporter \
        --quiet
fi
if ! gcloud compute firewall-rules describe "$HEALTH_CHECK_RULE_NAME" --project="$PROJECT_ID" &>/dev/null; then
    gcloud compute firewall-rules create "$HEALTH_CHECK_RULE_NAME" \
        --project="$PROJECT_ID" \
        --direction=INGRESS \
        --priority=1000 \
        --network=default \
        --action=ALLOW \
        --rules=tcp:80 \
        --source-ranges=130.211.0.0/22,35.191.0.0/16 \
        --target-tags=hw8-webserver \
        --quiet
fi

log "Ensuring reporter VM exists"
if ! gcloud compute instances describe "$REPORTER_VM" --zone="$ZONE_A" --project="$PROJECT_ID" &>/dev/null; then
    gcloud compute instances create "$REPORTER_VM" \
        --project="$PROJECT_ID" \
        --zone="$ZONE_A" \
        --machine-type="$REPORTER_MACHINE" \
        --image-family=debian-12 \
        --image-project=debian-cloud \
        --service-account="$REPORTER_SA" \
        --scopes=cloud-platform \
        --tags=hw8-reporter \
        --metadata="bucket-name=${BUCKET_NAME},subscription-id=${SUBSCRIPTION_ID}" \
        --metadata-from-file startup-script=service2_startup.sh \
        --quiet
fi

REPORTER_INTERNAL_IP="$(gcloud compute instances describe "$REPORTER_VM" \
    --zone="$ZONE_A" \
    --project="$PROJECT_ID" \
    --format='value(networkInterfaces[0].networkIP)')"
SERVICE2_URL="http://${REPORTER_INTERNAL_IP}:8080"

create_web_vm() {
    local vm_name="$1"
    local vm_zone="$2"

    if ! gcloud compute instances describe "$vm_name" --zone="$vm_zone" --project="$PROJECT_ID" &>/dev/null; then
        log "Creating web server VM ${vm_name} in ${vm_zone}"
        gcloud compute instances create "$vm_name" \
            --project="$PROJECT_ID" \
            --zone="$vm_zone" \
            --machine-type="$SERVER_MACHINE" \
            --image-family=debian-12 \
            --image-project=debian-cloud \
            --service-account="$WEBSERVER_SA" \
            --scopes=cloud-platform \
            --tags=hw8-webserver \
            --metadata="service2-url=${SERVICE2_URL},bucket-name=${BUCKET_NAME},topic-id=${TOPIC_ID}" \
            --metadata-from-file startup-script=startup.sh \
            --quiet
    fi
}

create_web_vm "$SERVER_A_VM" "$ZONE_A"
create_web_vm "$SERVER_B_VM" "$ZONE_B"

log "Ensuring unmanaged instance groups exist"
if ! gcloud compute instance-groups unmanaged describe "$INSTANCE_GROUP_A" --zone="$ZONE_A" --project="$PROJECT_ID" &>/dev/null; then
    gcloud compute instance-groups unmanaged create "$INSTANCE_GROUP_A" \
        --zone="$ZONE_A" \
        --project="$PROJECT_ID"
fi
if ! gcloud compute instance-groups unmanaged describe "$INSTANCE_GROUP_B" --zone="$ZONE_B" --project="$PROJECT_ID" &>/dev/null; then
    gcloud compute instance-groups unmanaged create "$INSTANCE_GROUP_B" \
        --zone="$ZONE_B" \
        --project="$PROJECT_ID"
fi

if ! gcloud compute instance-groups unmanaged list-instances "$INSTANCE_GROUP_A" \
    --zone="$ZONE_A" \
    --project="$PROJECT_ID" \
    --format='value(instance.basename())' | grep -x "$SERVER_A_VM" >/dev/null 2>&1; then
    gcloud compute instance-groups unmanaged add-instances "$INSTANCE_GROUP_A" \
        --instances="$SERVER_A_VM" \
        --zone="$ZONE_A" \
        --project="$PROJECT_ID"
fi
if ! gcloud compute instance-groups unmanaged list-instances "$INSTANCE_GROUP_B" \
    --zone="$ZONE_B" \
    --project="$PROJECT_ID" \
    --format='value(instance.basename())' | grep -x "$SERVER_B_VM" >/dev/null 2>&1; then
    gcloud compute instance-groups unmanaged add-instances "$INSTANCE_GROUP_B" \
        --instances="$SERVER_B_VM" \
        --zone="$ZONE_B" \
        --project="$PROJECT_ID"
fi

log "Ensuring regional health check exists"
if ! gcloud compute health-checks describe "$HC_NAME" --region="$REGION" --project="$PROJECT_ID" &>/dev/null; then
    gcloud compute health-checks create http "$HC_NAME" \
        --project="$PROJECT_ID" \
        --region="$REGION" \
        --port=80 \
        --request-path=/health \
        --check-interval=5s \
        --timeout=5s \
        --healthy-threshold=2 \
        --unhealthy-threshold=2
fi

log "Ensuring backend service exists"
if ! gcloud compute backend-services describe "$BACKEND_SERVICE_NAME" --region="$REGION" --project="$PROJECT_ID" &>/dev/null; then
    gcloud compute backend-services create "$BACKEND_SERVICE_NAME" \
        --project="$PROJECT_ID" \
        --region="$REGION" \
        --load-balancing-scheme=EXTERNAL \
        --protocol=TCP \
        --health-checks="$HC_NAME" \
        --health-checks-region="$REGION"
fi

if ! gcloud compute backend-services describe "$BACKEND_SERVICE_NAME" \
    --region="$REGION" \
    --project="$PROJECT_ID" \
    --format='value(backends.group.basename())' | grep -x "$INSTANCE_GROUP_A" >/dev/null 2>&1; then
    gcloud compute backend-services add-backend "$BACKEND_SERVICE_NAME" \
        --project="$PROJECT_ID" \
        --region="$REGION" \
        --instance-group="$INSTANCE_GROUP_A" \
        --instance-group-zone="$ZONE_A"
fi
if ! gcloud compute backend-services describe "$BACKEND_SERVICE_NAME" \
    --region="$REGION" \
    --project="$PROJECT_ID" \
    --format='value(backends.group.basename())' | grep -x "$INSTANCE_GROUP_B" >/dev/null 2>&1; then
    gcloud compute backend-services add-backend "$BACKEND_SERVICE_NAME" \
        --project="$PROJECT_ID" \
        --region="$REGION" \
        --instance-group="$INSTANCE_GROUP_B" \
        --instance-group-zone="$ZONE_B"
fi

log "Ensuring load balancer IP exists"
if ! gcloud compute addresses describe "$LB_IP_NAME" --region="$REGION" --project="$PROJECT_ID" &>/dev/null; then
    gcloud compute addresses create "$LB_IP_NAME" \
        --project="$PROJECT_ID" \
        --region="$REGION"
fi
LB_IP="$(gcloud compute addresses describe "$LB_IP_NAME" \
    --region="$REGION" \
    --project="$PROJECT_ID" \
    --format='value(address)')"

log "Ensuring forwarding rule exists"
if ! gcloud compute forwarding-rules describe "$FORWARDING_RULE_NAME" --region="$REGION" --project="$PROJECT_ID" &>/dev/null; then
    gcloud compute forwarding-rules create "$FORWARDING_RULE_NAME" \
        --project="$PROJECT_ID" \
        --region="$REGION" \
        --load-balancing-scheme=EXTERNAL \
        --address="$LB_IP_NAME" \
        --address-region="$REGION" \
        --ip-protocol=TCP \
        --ports=80 \
        --backend-service="$BACKEND_SERVICE_NAME" \
        --backend-service-region="$REGION"
fi

log ""
log "=========================================="
log "  Reporter VM: ${REPORTER_VM} (${ZONE_A})"
log "  Web VM A   : ${SERVER_A_VM} (${ZONE_A})"
log "  Web VM B   : ${SERVER_B_VM} (${ZONE_B})"
log "  LB IP      : http://${LB_IP}"
log "=========================================="
log "Check backend health with:"
log "  gcloud compute backend-services get-health ${BACKEND_SERVICE_NAME} --region=${REGION}"
