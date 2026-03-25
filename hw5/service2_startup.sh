#!/bin/bash
# Startup script for reporter VM.

set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

if [ -f /var/log/startup_already_done ]; then
    echo "Startup already completed."
    exit 0
fi

METADATA_URL="http://metadata.google.internal/computeMetadata/v1"
METADATA_HEADER="Metadata-Flavor: Google"
BUCKET_NAME=$(curl -s "${METADATA_URL}/instance/attributes/bucket-name" -H "${METADATA_HEADER}" || true)
PROJECT_ID=$(curl -s "${METADATA_URL}/project/project-id" -H "${METADATA_HEADER}" || true)

apt-get update -y
apt-get install -y python3 python3-pip python3-venv

mkdir -p /opt/hw5-service2
cd /opt/hw5-service2

python3 -m venv venv
source venv/bin/activate
pip install --upgrade pip
pip install flask google-cloud-pubsub

gsutil cp "gs://${BUCKET_NAME}/hw5/service2.py" /opt/hw5-service2/service2.py

cat > /etc/systemd/system/hw5-service2.service << EOF
[Unit]
Description=HW5 Forbidden Country Reporter
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=/opt/hw5-service2
Environment="PORT=8080"
Environment="PROJECT_ID=${PROJECT_ID}"
Environment="SUBSCRIPTION_ID=forbidden-sub"
ExecStart=/opt/hw5-service2/venv/bin/python /opt/hw5-service2/service2.py
Restart=always
RestartSec=5
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable hw5-service2
systemctl start hw5-service2

touch /var/log/startup_already_done
