#!/bin/bash
# Startup script for web server VM.

set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

if [ -f /var/log/startup_already_done ]; then
    echo "Startup already completed."
    exit 0
fi

METADATA_URL="http://metadata.google.internal/computeMetadata/v1"
METADATA_HEADER="Metadata-Flavor: Google"

SERVICE2_URL=$(curl -s "${METADATA_URL}/instance/attributes/service2-url" -H "${METADATA_HEADER}" || true)
BUCKET_NAME=$(curl -s "${METADATA_URL}/instance/attributes/bucket-name" -H "${METADATA_HEADER}" || true)
PROJECT_ID=$(curl -s "${METADATA_URL}/project/project-id" -H "${METADATA_HEADER}" || true)
DB_USER=$(curl -s "${METADATA_URL}/instance/attributes/db-user" -H "${METADATA_HEADER}" || true)
DB_PASS=$(curl -s "${METADATA_URL}/instance/attributes/db-pass" -H "${METADATA_HEADER}" || true)
DB_NAME=$(curl -s "${METADATA_URL}/instance/attributes/db-name" -H "${METADATA_HEADER}" || true)
DB_CONN_NAME=$(curl -s "${METADATA_URL}/instance/attributes/db-conn-name" -H "${METADATA_HEADER}" || true)

apt-get update -y
apt-get install -y python3 python3-pip python3-venv curl

mkdir -p /opt/hw5-server
cd /opt/hw5-server

python3 -m venv venv
source venv/bin/activate
pip install --upgrade pip
pip install flask google-cloud-storage google-cloud-pubsub google-cloud-logging requests sqlalchemy pg8000

gsutil cp "gs://${BUCKET_NAME}/hw5/server.py" /opt/hw5-server/server.py
gsutil cp "gs://${BUCKET_NAME}/hw5/setup_schema.py" /opt/hw5-server/setup_schema.py

curl -fsSL -o /usr/local/bin/cloud-sql-proxy \
    "https://storage.googleapis.com/cloud-sql-connectors/cloud-sql-proxy/v2.14.3/cloud-sql-proxy.linux.amd64"
chmod +x /usr/local/bin/cloud-sql-proxy

cat > /etc/systemd/system/cloud-sql-proxy.service << EOF
[Unit]
Description=Cloud SQL Auth Proxy
After=network.target

[Service]
Type=simple
User=root
ExecStart=/usr/local/bin/cloud-sql-proxy --address 127.0.0.1 --port 5432 ${DB_CONN_NAME}
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

cat > /etc/systemd/system/hw5-server.service << EOF
[Unit]
Description=HW5 Web Server
After=network.target cloud-sql-proxy.service

[Service]
Type=simple
User=root
WorkingDirectory=/opt/hw5-server
Environment="PORT=80"
Environment="PROJECT_ID=${PROJECT_ID}"
Environment="TOPIC_ID=forbidden"
Environment="BUCKET_NAME=${BUCKET_NAME}"
Environment="SERVICE2_URL=${SERVICE2_URL}"
Environment="DATABASE_URL=postgresql+pg8000://${DB_USER}:${DB_PASS}@127.0.0.1:5432/${DB_NAME}"
Environment="GCE_METADATA_MTLS_MODE=none"
Environment="NO_PROXY=metadata.google.internal,169.254.169.254,localhost,127.0.0.1"
ExecStart=/opt/hw5-server/venv/bin/python /opt/hw5-server/server.py
Restart=always
RestartSec=5
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable cloud-sql-proxy
systemctl start cloud-sql-proxy

DATABASE_URL="postgresql+pg8000://${DB_USER}:${DB_PASS}@127.0.0.1:5432/${DB_NAME}" \
  /opt/hw5-server/venv/bin/python /opt/hw5-server/setup_schema.py

systemctl enable hw5-server
systemctl start hw5-server

touch /var/log/startup_already_done
