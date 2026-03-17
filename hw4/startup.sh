#!/bin/bash
# Startup script for VM1 (web server)

if [ -f /var/log/startup_already_done ]; then
    echo "Startup script already ran once. Skipping."
    exit 0
fi

PROJECT_ID="lateral-shore-485121-i1"
SERVICE2_URL=$(curl -s "http://metadata.google.internal/computeMetadata/v1/instance/attributes/service2-url" \
    -H "Metadata-Flavor: Google" 2>/dev/null || echo "")

apt-get update -y
apt-get install -y python3 python3-pip python3-venv git

mkdir -p /opt/hw4-server
cd /opt/hw4-server

python3 -m venv venv
source venv/bin/activate
pip install --upgrade pip
pip install flask google-cloud-storage google-cloud-pubsub google-cloud-logging requests

gsutil cp gs://alan-assign2/server.py /opt/hw4-server/server.py

cat > /etc/systemd/system/hw4-server.service << EOF
[Unit]
Description=Web Server (Service 1)
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=/opt/hw4-server
Environment="PORT=80"
Environment="SERVICE2_URL=${SERVICE2_URL}"
ExecStart=/opt/hw4-server/venv/bin/python /opt/hw4-server/server.py
Restart=always
RestartSec=5
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable hw4-server
systemctl start hw4-server

touch /var/log/startup_already_done
