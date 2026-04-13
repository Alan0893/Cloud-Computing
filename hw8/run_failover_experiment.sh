#!/bin/bash
set -euo pipefail
LB="${LB:-http://35.197.24.226}"
VM_B="${VM_B:-hw8-web-b-us-west1}"
ZONE_B="${ZONE_B:-us-west1-b}"
LOG="${LOG:-/tmp/hw8_failover.log}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

rm -f "$LOG"
python3 -c "import datetime; print('EXPERIMENT_START', datetime.datetime.now(datetime.timezone.utc).isoformat())" | tee -a "$LOG"

cd "$SCRIPT_DIR"
python3 lb_client.py --server "$LB" --path health --interval 1 --requests 0 --timeout 15 >>"$LOG" 2>&1 &
CLIENT_PID=$!

sleep 15
python3 -c "import datetime; print('MARKER_T0_STOP', datetime.datetime.now(datetime.timezone.utc).isoformat())" | tee -a "$LOG"
gcloud compute ssh "$VM_B" --zone="$ZONE_B" --tunnel-through-iap --command="sudo systemctl stop hw8-server" >>"$LOG" 2>&1

sleep 130

python3 -c "import datetime; print('MARKER_T0_START', datetime.datetime.now(datetime.timezone.utc).isoformat())" | tee -a "$LOG"
gcloud compute ssh "$VM_B" --zone="$ZONE_B" --tunnel-through-iap --command="sudo systemctl start hw8-server" >>"$LOG" 2>&1

sleep 100
kill "$CLIENT_PID" 2>/dev/null || true
wait "$CLIENT_PID" 2>/dev/null || true

python3 -c "import datetime; print('EXPERIMENT_END', datetime.datetime.now(datetime.timezone.utc).isoformat())" | tee -a "$LOG"
echo "Log written to $LOG"
