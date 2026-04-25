"""HW9 web server — containerized for GKE.
"""

import os
import socket

import google.cloud.logging
from flask import Flask, Response, request
from google.cloud import pubsub_v1, storage

app = Flask(__name__)

PROJECT_ID = os.environ.get("PROJECT_ID", "")
TOPIC_ID = os.environ.get("TOPIC_ID", "hw9-forbidden")
BUCKET_NAME = os.environ.get("BUCKET_NAME", "alan-assign2")

POD_NAME = os.environ.get("HOSTNAME", socket.gethostname())
POD_HEADER = "X-Pod-Name"

FORBIDDEN_COUNTRIES = {
    "North Korea",
    "Iran",
    "Cuba",
    "Myanmar",
    "Iraq",
    "Libya",
    "Sudan",
    "Zimbabwe",
    "Syria",
}

ALLOWED_METHODS = {"GET"}
NOT_IMPLEMENTED_METHODS = {
    "PUT",
    "POST",
    "DELETE",
    "HEAD",
    "CONNECT",
    "OPTIONS",
    "TRACE",
    "PATCH",
}

logging_client = google.cloud.logging.Client()
logger = logging_client.logger("hw9-service1")
storage_client = storage.Client()
publisher = pubsub_v1.PublisherClient()


def get_client_country(req):
    return req.headers.get("X-country", "").strip()


def make_response(body, status, mimetype="text/plain"):
    response = Response(body, status=status, mimetype=mimetype)
    response.headers[POD_HEADER] = POD_NAME
    return response


@app.route("/health", methods=["GET"])
def health_check():
    return make_response("ok", status=200)


@app.route(
    "/",
    defaults={"filename": ""},
    methods=list(ALLOWED_METHODS | NOT_IMPLEMENTED_METHODS),
)
@app.route(
    "/<path:filename>",
    methods=list(ALLOWED_METHODS | NOT_IMPLEMENTED_METHODS),
)
def handle_request(filename):
    method = request.method

    if method in NOT_IMPLEMENTED_METHODS:
        msg = f"501 Not Implemented: method={method} path=/{filename}"
        logger.log_struct(
            {
                "event": "not_implemented",
                "message": msg,
                "method": method,
                "path": f"/{filename}",
                "pod": POD_NAME,
            },
            severity="WARNING",
        )
        return make_response("Not Implemented", status=501)

    country = get_client_country(request)
    if country in FORBIDDEN_COUNTRIES:
        msg = (
            f"Forbidden export: country={country} path=/{filename} "
            f"pod={POD_NAME}"
        )
        logger.log_struct(
            {
                "event": "forbidden_country",
                "message": msg,
                "country": country,
                "path": f"/{filename}",
                "pod": POD_NAME,
            },
            severity="CRITICAL",
        )

        if PROJECT_ID:
            topic_path = publisher.topic_path(PROJECT_ID, TOPIC_ID)
            try:
                future = publisher.publish(topic_path, data=msg.encode("utf-8"))
                future.result(timeout=5)
            except Exception as exc:
                logger.log_struct(
                    {
                        "event": "pubsub_publish_failed",
                        "message": f"Failed to publish to Pub/Sub: {exc}",
                    },
                    severity="ERROR",
                )

        return make_response("Permission Denied", status=403)

    if not filename:
        return make_response("No filename provided", status=400)

    if filename.startswith(BUCKET_NAME + "/"):
        filename = filename[len(BUCKET_NAME) + 1 :]

    if not filename.endswith(".html"):
        filename += ".html"

    bucket = storage_client.bucket(BUCKET_NAME)
    blob = bucket.blob(f"pages/{filename}")

    if not blob.exists():
        msg = f"404 Not Found: path=/{filename}"
        logger.log_struct(
            {
                "event": "not_found",
                "message": msg,
                "path": f"/{filename}",
                "pod": POD_NAME,
            },
            severity="WARNING",
        )
        return make_response("Not Found", status=404)

    content = blob.download_as_text()
    return make_response(content, status=200, mimetype="text/html")


if __name__ == "__main__":
    port = int(os.environ.get("PORT", 8080))
    print(f"HW9 web server starting on port {port} (pod={POD_NAME})", flush=True)
    app.run(host="0.0.0.0", port=port)
