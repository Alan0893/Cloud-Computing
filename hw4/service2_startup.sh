#!/bin/bash
# Startup script for VM3 (forbidden country reporter - Service 2)

if [ -f /var/log/startup_already_done ]; then
    echo "Startup script already ran once. Skipping."
    exit 0
fi

apt-get update -y
apt-get install -y python3 python3-pip python3-venv git

mkdir -p /opt/hw4-service2
cd /opt/hw4-service2

python3 -m venv venv
source venv/bin/activate
pip install --upgrade pip
pip install flask google-cloud-pubsub requests

gsutil cp gs://alan-assign2/service2.py /opt/hw4-service2/service2.py

cat > /etc/systemd/system/hw4-service2.service << EOF
[Unit]
Description=HW4 Forbidden Country Reporter (Service 2)
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=/opt/hw4-service2
Environment="PORT=8080"
ExecStart=/opt/hw4-service2/venv/bin/python /opt/hw4-service2/service2.py
Restart=always
RestartSec=5
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable hw4-service2
systemctl start hw4-service2

touch /var/log/startup_already_done
