import os
import requests
from flask import Flask, request, Response
from google.cloud import storage, pubsub_v1
import google.cloud.logging

app = Flask(__name__)

PROJECT_ID = "lateral-shore-485121-i1"
TOPIC_ID = "forbidden"
BUCKET_NAME = "alan-assign2"
SERVICE2_URL = os.environ.get("SERVICE2_URL", "")

FORBIDDEN_COUNTRIES = [
    "North Korea", "Iran", "Cuba", "Myanmar",
    "Iraq", "Libya", "Sudan", "Zimbabwe", "Syria"
]

ALLOWED_METHODS = {"GET"}
ALL_HTTP_METHODS = {"PUT", "POST", "DELETE", "HEAD", "CONNECT", "OPTIONS", "TRACE", "PATCH"}

logging_client = google.cloud.logging.Client()
logger = logging_client.logger("hw4-service1")

storage_client = storage.Client()
publisher = pubsub_v1.PublisherClient()

def get_client_country(req):
    """Extract country from X-country header."""
    return req.headers.get("X-country", "").strip()


@app.route("/", defaults={"filename": ""}, methods=list(ALLOWED_METHODS | ALL_HTTP_METHODS))
@app.route("/<path:filename>", methods=list(ALLOWED_METHODS | ALL_HTTP_METHODS))
def handle_request(filename):
    method = request.method

    if method in ALL_HTTP_METHODS:
        msg = f"Method {method} not implemented. Path: /{filename}"
        logger.log_struct(
            {"message": msg, "method": method, "path": f"/{filename}"},
            severity="WARNING"
        )
        return Response("Not Implemented", status=501)

    country = get_client_country(request)
    if country in FORBIDDEN_COUNTRIES:
        msg = f"Forbidden: Export to {country} is prohibited. Path: /{filename}"
        logger.log_struct(
            {"message": msg, "country": country, "path": f"/{filename}"},
            severity="CRITICAL"
        )

        topic_path = publisher.topic_path(PROJECT_ID, TOPIC_ID)
        try:
            publisher.publish(topic_path, data=msg.encode("utf-8"))
        except Exception as e:
            logger.log_struct(
                {"message": f"Failed to publish to Pub/Sub: {e}"},
                severity="ERROR"
            )

        if SERVICE2_URL:
            try:
                requests.post(SERVICE2_URL + "/forbidden", json={"country": country, "path": f"/{filename}"}, timeout=2)
            except Exception:
                pass

        return Response("Permission Denied", status=400)

    if not filename:
        return Response("No filename provided", status=400)

    if filename.startswith(BUCKET_NAME + "/"):
        filename = filename[len(BUCKET_NAME) + 1:]

    if not filename.endswith(".html"):
        filename = filename + ".html"

    bucket = storage_client.bucket(BUCKET_NAME)
    blob = bucket.blob(f"pages/{filename}")

    if not blob.exists():
        msg = f"File pages/{filename} not found"
        logger.log_struct(
            {"message": msg, "path": f"/{filename}"},
            severity="WARNING"
        )
        return Response("Not Found", status=404)

    content = blob.download_as_text()
    return Response(content, status=200, mimetype="text/html")

if __name__ == "__main__":
    port = int(os.environ.get("PORT", 80))
    app.run(host="0.0.0.0", port=port)
