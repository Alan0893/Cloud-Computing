#!/bin/bash
# Startup script for HW8 web server VMs.

set -euo pipefail

if [ -f /var/log/startup_already_done ]; then
    echo "Startup script already ran once. Skipping."
    exit 0
fi

METADATA_URL="http://metadata.google.internal/computeMetadata/v1"
METADATA_HEADER="Metadata-Flavor: Google"

SERVICE2_URL=$(curl -s "${METADATA_URL}/instance/attributes/service2-url" -H "${METADATA_HEADER}" 2>/dev/null || echo "")
BUCKET_NAME=$(curl -s "${METADATA_URL}/instance/attributes/bucket-name" -H "${METADATA_HEADER}" 2>/dev/null || echo "alan-assign2")
PROJECT_ID=$(curl -s "${METADATA_URL}/project/project-id" -H "${METADATA_HEADER}" 2>/dev/null || echo "")
SERVER_ZONE=$(curl -s "${METADATA_URL}/instance/zone" -H "${METADATA_HEADER}" 2>/dev/null | awk -F/ '{print $NF}')
TOPIC_ID=$(curl -s "${METADATA_URL}/instance/attributes/topic-id" -H "${METADATA_HEADER}" 2>/dev/null || echo "hw8-forbidden")

apt-get update -y
apt-get install -y python3 python3-pip python3-venv git

mkdir -p /opt/hw8-server
cd /opt/hw8-server

python3 -m venv venv
source venv/bin/activate
pip install --upgrade pip
pip install flask google-cloud-storage google-cloud-pubsub google-cloud-logging requests

gsutil cp "gs://${BUCKET_NAME}/hw8/server.py" /opt/hw8-server/server.py

cat > /etc/systemd/system/hw8-server.service << EOF
[Unit]
Description=HW8 Web Server (Service 1)
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=/opt/hw8-server
Environment="PORT=80"
Environment="PROJECT_ID=${PROJECT_ID}"
Environment="TOPIC_ID=${TOPIC_ID}"
Environment="BUCKET_NAME=${BUCKET_NAME}"
Environment="SERVICE2_URL=${SERVICE2_URL}"
Environment="SERVER_ZONE=${SERVER_ZONE}"
ExecStart=/opt/hw8-server/venv/bin/python /opt/hw8-server/server.py
Restart=always
RestartSec=5
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable hw8-server
systemctl start hw8-server

touch /var/log/startup_already_done
