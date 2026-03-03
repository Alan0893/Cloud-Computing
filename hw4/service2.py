import os
from flask import Flask, request, jsonify
from google.cloud import pubsub_v1
import threading

app = Flask(__name__)

PROJECT_ID = "lateral-shore-485121-i1"
SUBSCRIPTION_ID = "forbidden-sub"

subscriber = pubsub_v1.SubscriberClient()
subscription_path = subscriber.subscription_path(PROJECT_ID, SUBSCRIPTION_ID)

def pubsub_callback(message):
    error_text = message.data.decode("utf-8")
    print(f"[FORBIDDEN ACCESS via Pub/Sub] {error_text}", flush=True)
    message.ack()

def start_pubsub_listener():
    print(f"Listening for Pub/Sub messages on {subscription_path}...", flush=True)
    streaming_pull_future = subscriber.subscribe(subscription_path, callback=pubsub_callback)
    try:
        streaming_pull_future.result()
    except Exception as e:
        print(f"Pub/Sub listener error: {e}", flush=True)
        streaming_pull_future.cancel()

@app.route("/forbidden", methods=["POST"])
def forbidden():
    data = request.get_json(silent=True) or {}
    country = data.get("country", "Unknown")
    path = data.get("path", "/")
    msg = f"[FORBIDDEN ACCESS via HTTP] Country: {country}, Path: {path}"
    print(msg, flush=True)
    return jsonify({"status": "received"}), 200

@app.route("/health", methods=["GET"])
def health():
    return jsonify({"status": "ok"}), 200

if __name__ == "__main__":
    listener_thread = threading.Thread(target=start_pubsub_listener, daemon=True)
    listener_thread.start()

    port = int(os.environ.get("PORT", 8080))
    print(f"Service 2 starting on port {port}...", flush=True)
    app.run(host="0.0.0.0", port=port