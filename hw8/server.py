import os

import google.cloud.logging
import requests
from flask import Flask, Response, request
from google.cloud import pubsub_v1, storage

app = Flask(__name__)

PROJECT_ID = os.environ.get("PROJECT_ID", "lateral-shore-485121-i1")
TOPIC_ID = os.environ.get("TOPIC_ID", "hw8-forbidden")
BUCKET_NAME = os.environ.get("BUCKET_NAME", "alan-assign2")
SERVICE2_URL = os.environ.get("SERVICE2_URL", "")
SERVER_ZONE = os.environ.get("SERVER_ZONE", "").strip()

ZONE_HEADER = "X-Server-Zone"
ZONE_METADATA_URL = "http://metadata.google.internal/computeMetadata/v1/instance/zone"
ZONE_METADATA_HEADERS = {"Metadata-Flavor": "Google"}

FORBIDDEN_COUNTRIES = [
    "North Korea",
    "Iran",
    "Cuba",
    "Myanmar",
    "Iraq",
    "Libya",
    "Sudan",
    "Zimbabwe",
    "Syria",
]

ALLOWED_METHODS = {"GET"}
ALL_HTTP_METHODS = {"PUT", "POST", "DELETE", "HEAD", "CONNECT", "OPTIONS", "TRACE", "PATCH"}

logging_client = google.cloud.logging.Client()
logger = logging_client.logger("hw8-service1")
storage_client = storage.Client()
publisher = pubsub_v1.PublisherClient()


def get_client_country(req):
    return req.headers.get("X-country", "").strip()


def get_server_zone():
    global SERVER_ZONE

    if SERVER_ZONE:
        return SERVER_ZONE

    try:
        zone_path = requests.get(
            ZONE_METADATA_URL,
            headers=ZONE_METADATA_HEADERS,
            timeout=1,
        ).text.strip()
        if zone_path:
            SERVER_ZONE = zone_path.rsplit("/", 1)[-1]
            return SERVER_ZONE
    except Exception as exc:
        logger.log_struct(
            {"message": f"Failed to fetch instance zone metadata: {exc}"},
            severity="WARNING",
        )

    SERVER_ZONE = "unknown"
    return SERVER_ZONE


def response_with_zone(body, status, mimetype="text/plain"):
    response = Response(body, status=status, mimetype=mimetype)
    response.headers[ZONE_HEADER] = get_server_zone()
    return response


@app.route("/health", methods=["GET"])
def health_check():
    return response_with_zone("ok", status=200)


@app.route("/", defaults={"filename": ""}, methods=list(ALLOWED_METHODS | ALL_HTTP_METHODS))
@app.route("/<path:filename>", methods=list(ALLOWED_METHODS | ALL_HTTP_METHODS))
def handle_request(filename):
    method = request.method

    if method in ALL_HTTP_METHODS:
        msg = f"Method {method} not implemented. Path: /{filename}"
        logger.log_struct(
            {"message": msg, "method": method, "path": f"/{filename}"},
            severity="WARNING",
        )
        return response_with_zone("Not Implemented", status=501)

    country = get_client_country(request)
    if country in FORBIDDEN_COUNTRIES:
        msg = f"Forbidden: Export to {country} is prohibited. Path: /{filename}"
        logger.log_struct(
            {"message": msg, "country": country, "path": f"/{filename}"},
            severity="CRITICAL",
        )

        topic_path = publisher.topic_path(PROJECT_ID, TOPIC_ID)
        try:
            publisher.publish(topic_path, data=msg.encode("utf-8"))
        except Exception as exc:
            logger.log_struct(
                {"message": f"Failed to publish to Pub/Sub: {exc}"},
                severity="ERROR",
            )

        if SERVICE2_URL:
            try:
                requests.post(
                    SERVICE2_URL + "/forbidden",
                    json={"country": country, "path": f"/{filename}"},
                    timeout=2,
                )
            except Exception:
                pass

        return response_with_zone("Permission Denied", status=400)

    if not filename:
        return response_with_zone("No filename provided", status=400)

    if filename.startswith(BUCKET_NAME + "/"):
        filename = filename[len(BUCKET_NAME) + 1 :]

    if not filename.endswith(".html"):
        filename += ".html"

    bucket = storage_client.bucket(BUCKET_NAME)
    blob = bucket.blob(f"pages/{filename}")

    if not blob.exists():
        msg = f"File pages/{filename} not found"
        logger.log_struct(
            {"message": msg, "path": f"/{filename}"},
            severity="WARNING",
        )
        return response_with_zone("Not Found", status=404)

    content = blob.download_as_text()
    return response_with_zone(content, status=200, mimetype="text/html")


if __name__ == "__main__":
    port = int(os.environ.get("PORT", 80))
    app.run(host="0.0.0.0", port=port)
