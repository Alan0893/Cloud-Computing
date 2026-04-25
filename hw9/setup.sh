#!/bin/bash
# setup.sh - provision all infrastructure for HW9.

set -euo pipefail

PROJECT_ID="$(gcloud config get-value project)"
REGION="${REGION:-us-west1}"
ZONE="${ZONE:-us-west1-a}"

BUCKET_NAME="${BUCKET_NAME:-alan-assign2}"

CLUSTER_NAME="${CLUSTER_NAME:-hw9-cluster}"

REPO_NAME="${REPO_NAME:-hw9-images}"
IMAGE_NAME="${IMAGE_NAME:-hw9-webserver}"
IMAGE_TAG="${IMAGE_TAG:-v1}"
IMAGE="${REGION}-docker.pkg.dev/${PROJECT_ID}/${REPO_NAME}/${IMAGE_NAME}:${IMAGE_TAG}"

WEBSERVER_GSA_NAME="hw9-webserver-sa"
WEBSERVER_GSA="${WEBSERVER_GSA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com"

REPORTER_GSA_NAME="hw9-reporter-sa"
REPORTER_GSA="${REPORTER_GSA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com"

KSA_NAME="hw9-webserver-ksa"
NAMESPACE="default"

TOPIC_ID="${TOPIC_ID:-hw9-forbidden}"
SUBSCRIPTION_ID="${SUBSCRIPTION_ID:-hw9-forbidden-sub}"

REPORTER_VM="${REPORTER_VM:-hw9-reporter}"
CLIENT_VM="${CLIENT_VM:-hw9-client}"
REPORTER_MACHINE="${REPORTER_MACHINE:-e2-micro}"
CLIENT_MACHINE="${CLIENT_MACHINE:-e2-medium}"

log() { echo "[$(date '+%H:%M:%S')] $*"; }

cd "$(dirname "$0")"

log "Project=${PROJECT_ID}  Region=${REGION}  Zone=${ZONE}"

# --------------------------------------------------------------------------
# 1. Enable APIs
# --------------------------------------------------------------------------
log "Enabling required Google Cloud APIs"
gcloud services enable \
    container.googleapis.com \
    artifactregistry.googleapis.com \
    cloudbuild.googleapis.com \
    pubsub.googleapis.com \
    logging.googleapis.com \
    storage.googleapis.com \
    iamcredentials.googleapis.com \
    --project="$PROJECT_ID" --quiet

# --------------------------------------------------------------------------
# 2. GCS bucket: holds page files (already populated from prior HWs) plus
#    the http-client binary and lb_client.py for the client VM.
# --------------------------------------------------------------------------
log "Ensuring GCS bucket gs://${BUCKET_NAME} exists"
if ! gsutil ls "gs://${BUCKET_NAME}" &>/dev/null; then
    gsutil mb -p "$PROJECT_ID" -l "$REGION" "gs://${BUCKET_NAME}"
fi

log "Uploading service2.py, http-client and lb_client.py to gs://${BUCKET_NAME}/hw9/"
gsutil cp service2/service2.py "gs://${BUCKET_NAME}/hw9/service2.py"
gsutil cp http-client          "gs://${BUCKET_NAME}/hw9/http-client"
gsutil cp lb_client.py         "gs://${BUCKET_NAME}/hw9/lb_client.py"

# --------------------------------------------------------------------------
# 3. Service accounts (GCP-side)
# --------------------------------------------------------------------------
log "Creating GCP service accounts (web server + reporter)"
CREATED_SA=0
if ! gcloud iam service-accounts describe "$WEBSERVER_GSA" --project="$PROJECT_ID" &>/dev/null; then
    gcloud iam service-accounts create "$WEBSERVER_GSA_NAME" \
        --display-name="HW9 Web Server SA" --project="$PROJECT_ID"
    CREATED_SA=1
fi
if ! gcloud iam service-accounts describe "$REPORTER_GSA" --project="$PROJECT_ID" &>/dev/null; then
    gcloud iam service-accounts create "$REPORTER_GSA_NAME" \
        --display-name="HW9 Reporter SA" --project="$PROJECT_ID"
    CREATED_SA=1
fi
if [ "$CREATED_SA" -eq 1 ]; then
    log "Sleeping briefly to let new service accounts propagate"
    sleep 15
fi

log "Granting IAM roles to ${WEBSERVER_GSA}"
for ROLE in roles/storage.objectViewer roles/pubsub.publisher roles/logging.logWriter; do
    gcloud projects add-iam-policy-binding "$PROJECT_ID" \
        --member="serviceAccount:${WEBSERVER_GSA}" \
        --role="$ROLE" --quiet >/dev/null
done

log "Granting IAM roles to ${REPORTER_GSA}"
for ROLE in roles/storage.objectViewer roles/pubsub.subscriber roles/logging.logWriter; do
    gcloud projects add-iam-policy-binding "$PROJECT_ID" \
        --member="serviceAccount:${REPORTER_GSA}" \
        --role="$ROLE" --quiet >/dev/null
done

# --------------------------------------------------------------------------
# 4. Pub/Sub topic + subscription
# --------------------------------------------------------------------------
log "Creating Pub/Sub topic ${TOPIC_ID} and subscription ${SUBSCRIPTION_ID}"
if ! gcloud pubsub topics describe "$TOPIC_ID" --project="$PROJECT_ID" &>/dev/null; then
    gcloud pubsub topics create "$TOPIC_ID" --project="$PROJECT_ID"
fi
if ! gcloud pubsub subscriptions describe "$SUBSCRIPTION_ID" --project="$PROJECT_ID" &>/dev/null; then
    gcloud pubsub subscriptions create "$SUBSCRIPTION_ID" \
        --topic="$TOPIC_ID" --project="$PROJECT_ID"
fi

# --------------------------------------------------------------------------
# 5. Artifact Registry repo + build the container image with Cloud Build
# --------------------------------------------------------------------------
log "Ensuring Artifact Registry repo ${REPO_NAME} exists"
if ! gcloud artifacts repositories describe "$REPO_NAME" \
        --location="$REGION" --project="$PROJECT_ID" &>/dev/null; then
    gcloud artifacts repositories create "$REPO_NAME" \
        --repository-format=docker \
        --location="$REGION" \
        --description="HW9 container images" \
        --project="$PROJECT_ID"
fi

log "Building image ${IMAGE} with Cloud Build (this takes 1-2 min)"
gcloud builds submit server \
    --tag "$IMAGE" \
    --project="$PROJECT_ID" >/dev/null

# --------------------------------------------------------------------------
# 6. GKE Autopilot cluster
# --------------------------------------------------------------------------
log "Ensuring GKE Autopilot cluster ${CLUSTER_NAME} exists in ${REGION}"
if ! gcloud container clusters describe "$CLUSTER_NAME" \
        --region="$REGION" --project="$PROJECT_ID" &>/dev/null; then
    gcloud container clusters create-auto "$CLUSTER_NAME" \
        --region="$REGION" --project="$PROJECT_ID" --quiet
fi

log "Fetching kubectl credentials"
gcloud container clusters get-credentials "$CLUSTER_NAME" \
    --region="$REGION" --project="$PROJECT_ID"

# --------------------------------------------------------------------------
# 7. Workload Identity binding: K8s SA -> GCP SA
# --------------------------------------------------------------------------
log "Binding Kubernetes SA ${NAMESPACE}/${KSA_NAME} to ${WEBSERVER_GSA}"
gcloud iam service-accounts add-iam-policy-binding "$WEBSERVER_GSA" \
    --role="roles/iam.workloadIdentityUser" \
    --member="serviceAccount:${PROJECT_ID}.svc.id.goog[${NAMESPACE}/${KSA_NAME}]" \
    --project="$PROJECT_ID" --quiet >/dev/null

# --------------------------------------------------------------------------
# 8. Render and apply Kubernetes manifests
# --------------------------------------------------------------------------
log "Rendering Kubernetes manifests"
export PROJECT_ID IMAGE TOPIC_ID BUCKET_NAME WEBSERVER_SA="$WEBSERVER_GSA"

RENDERED_DIR="$(mktemp -d)"
envsubst < k8s/deployment.yaml > "${RENDERED_DIR}/deployment.yaml"
envsubst < k8s/service.yaml    > "${RENDERED_DIR}/service.yaml"

log "Applying Kubernetes manifests"
kubectl apply -f "${RENDERED_DIR}/deployment.yaml"
kubectl apply -f "${RENDERED_DIR}/service.yaml"
kubectl rollout status deployment/hw9-webserver --timeout=5m

# --------------------------------------------------------------------------
# 9. Wait for the LoadBalancer to publish an external IP
# --------------------------------------------------------------------------
log "Waiting for LoadBalancer external IP (this can take a couple of minutes)"
LB_IP=""
for _ in $(seq 1 60); do
    LB_IP="$(kubectl get svc hw9-webserver \
        -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)"
    if [ -n "$LB_IP" ]; then
        break
    fi
    sleep 5
done
if [ -z "$LB_IP" ]; then
    echo "Timed out waiting for LoadBalancer IP" >&2
    exit 1
fi
SERVER_URL="http://${LB_IP}"
log "Web server reachable at ${SERVER_URL}"

# --------------------------------------------------------------------------
# 10. Reporter VM (service 2): subscribes to Pub/Sub
# --------------------------------------------------------------------------
log "Creating reporter VM ${REPORTER_VM} in ${ZONE}"
if ! gcloud compute instances describe "$REPORTER_VM" --zone="$ZONE" --project="$PROJECT_ID" &>/dev/null; then
    gcloud compute instances create "$REPORTER_VM" \
        --project="$PROJECT_ID" \
        --zone="$ZONE" \
        --machine-type="$REPORTER_MACHINE" \
        --image-family=debian-12 \
        --image-project=debian-cloud \
        --service-account="$REPORTER_GSA" \
        --scopes=cloud-platform \
        --tags=hw9-reporter \
        --metadata="bucket-name=${BUCKET_NAME},subscription-id=${SUBSCRIPTION_ID}" \
        --metadata-from-file startup-script=service2_startup.sh \
        --quiet
fi

# --------------------------------------------------------------------------
# 11. Client VM: holds the http-client binary + lb_client.py
# --------------------------------------------------------------------------
log "Creating client VM ${CLIENT_VM} in ${ZONE}"
if ! gcloud compute instances describe "$CLIENT_VM" --zone="$ZONE" --project="$PROJECT_ID" &>/dev/null; then
    gcloud compute instances create "$CLIENT_VM" \
        --project="$PROJECT_ID" \
        --zone="$ZONE" \
        --machine-type="$CLIENT_MACHINE" \
        --image-family=debian-12 \
        --image-project=debian-cloud \
        --scopes=cloud-platform \
        --tags=hw9-client \
        --metadata="bucket-name=${BUCKET_NAME},server-url=${SERVER_URL}" \
        --metadata-from-file startup-script=client_startup.sh \
        --quiet
fi

log ""
log "=========================================="
log "  HW9 infrastructure ready"
log "=========================================="
log "  GKE cluster   : ${CLUSTER_NAME}  (${REGION})"
log "  Image         : ${IMAGE}"
log "  Web server URL: ${SERVER_URL}"
log "  Reporter VM   : ${REPORTER_VM}  (${ZONE})"
log "  Client VM     : ${CLIENT_VM}    (${ZONE})"
log "=========================================="
log ""
log "Open a browser and try:    ${SERVER_URL}/page1"
log "                           ${SERVER_URL}/no-such-file   (404)"
log ""
log "Tail reporter output with:"
log "  gcloud compute ssh ${REPORTER_VM} --zone=${ZONE} \\"
log "    --command='sudo journalctl -u hw9-service2 -f -n 50'"
log ""
log "Drive load from the client VM with:"
log "  gcloud compute ssh ${CLIENT_VM} --zone=${ZONE}"
log "  cat /opt/hw9-client/README.txt"
