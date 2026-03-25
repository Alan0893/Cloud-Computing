#!/bin/bash
# Run two concurrent client processes with the same random seed.

set -euo pipefail

if [ $# -lt 2 ]; then
    echo "Usage: $0 <server-ip-or-url> <seed> [requests-per-client]"
    echo "Example: $0 http://34.10.10.10 123 50000"
    exit 1
fi

SERVER="$1"
SEED="$2"
REQUESTS="${3:-50000}"

CLIENT_CMD_TEMPLATE="${CLIENT_CMD_TEMPLATE:-./http-client --server \"${SERVER}\" --seed \"${SEED}\" --requests \"${REQUESTS}\"}"

echo "Running two clients with identical seed=${SEED}, requests=${REQUESTS}"
echo "Client command template: ${CLIENT_CMD_TEMPLATE}"

eval "${CLIENT_CMD_TEMPLATE}" > client1.log 2>&1 &
PID1=$!
eval "${CLIENT_CMD_TEMPLATE}" > client2.log 2>&1 &
PID2=$!

wait "$PID1"
wait "$PID2"

echo "Both clients finished."
echo "Logs: client1.log, client2.log"
