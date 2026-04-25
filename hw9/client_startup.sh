#!/bin/bash
# Startup script for the HW9 client VM (drives the http-client + curl).

set -euo pipefail

if [ -f /var/log/startup_already_done ]; then
    echo "Startup script already ran once. Skipping."
    exit 0
fi

METADATA_URL="http://metadata.google.internal/computeMetadata/v1"
METADATA_HEADER="Metadata-Flavor: Google"

BUCKET_NAME=$(curl -s "${METADATA_URL}/instance/attributes/bucket-name" -H "${METADATA_HEADER}" 2>/dev/null || echo "alan-assign2")
SERVER_URL=$(curl -s "${METADATA_URL}/instance/attributes/server-url" -H "${METADATA_HEADER}" 2>/dev/null || echo "")

apt-get update -y
apt-get install -y python3 python3-pip python3-venv curl

mkdir -p /opt/hw9-client
cd /opt/hw9-client

gsutil cp "gs://${BUCKET_NAME}/hw9/http-client" /opt/hw9-client/http-client
gsutil cp "gs://${BUCKET_NAME}/hw9/lb_client.py" /opt/hw9-client/lb_client.py
chmod +x /opt/hw9-client/http-client

cat > /opt/hw9-client/README.txt << EOF
HW9 client VM
=============

Server URL : ${SERVER_URL}

# Drive a few hundred random GETs through the provided http-client:
./http-client -server ${SERVER_URL} -nrequests 300

# Drive deterministic requests with the included Python client:
python3 lb_client.py --server ${SERVER_URL} --requests 100 --interval 0.05 \\
    --paths "page1,page2,page3,does-not-exist"

# 404 demo (file does not exist):
curl -i ${SERVER_URL}/no-such-file

# 501 demo (method not implemented):
curl -i -X POST   ${SERVER_URL}/page1
curl -i -X DELETE ${SERVER_URL}/page1

# Forbidden-country demo (sends a banned country header):
curl -i -H "X-country: North Korea" ${SERVER_URL}/page1
EOF

touch /var/log/startup_already_done
