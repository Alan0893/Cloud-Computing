#!/bin/bash
# Startup script for the HW9 reporter VM (service 2).

set -euo pipefail

if [ -f /var/log/startup_already_done ]; then
    echo "Startup script already ran once. Skipping."
    exit 0
fi

METADATA_URL="http://metadata.google.internal/computeMetadata/v1"
METADATA_HEADER="Metadata-Flavor: Google"

PROJECT_ID=$(curl -s "${METADATA_URL}/project/project-id" -H "${METADATA_HEADER}")
BUCKET_NAME=$(curl -s "${METADATA_URL}/instance/attributes/bucket-name" -H "${METADATA_HEADER}" 2>/dev/null || echo "alan-assign2")
SUBSCRIPTION_ID=$(curl -s "${METADATA_URL}/instance/attributes/subscription-id" -H "${METADATA_HEADER}" 2>/dev/null || echo "hw9-forbidden-sub")

apt-get update -y
apt-get install -y python3 python3-pip python3-venv

mkdir -p /opt/hw9-service2
cd /opt/hw9-service2

python3 -m venv venv
source venv/bin/activate
pip install --upgrade pip
pip install google-cloud-pubsub

gsutil cp "gs://${BUCKET_NAME}/hw9/service2.py" /opt/hw9-service2/service2.py

cat > /etc/systemd/system/hw9-service2.service << EOF
[Unit]
Description=HW9 Forbidden Country Reporter (Service 2)
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=/opt/hw9-service2
Environment="PROJECT_ID=${PROJECT_ID}"
Environment="SUBSCRIPTION_ID=${SUBSCRIPTION_ID}"
ExecStart=/opt/hw9-service2/venv/bin/python /opt/hw9-service2/service2.py
Restart=always
RestartSec=5
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable hw9-service2
systemctl start hw9-service2

touch /var/log/startup_already_done
