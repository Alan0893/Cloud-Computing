import os
import time
from datetime import datetime, timezone
from typing import Optional

import requests
from flask import Flask, Response, request
from google.cloud import logging as cloud_logging
from google.cloud import pubsub_v1
from google.cloud import storage
from sqlalchemy import Boolean, Column, DateTime, Integer, String, create_engine, text
from sqlalchemy.orm import declarative_base, sessionmaker

app = Flask(__name__)

PROJECT_ID = os.environ.get("PROJECT_ID", "lateral-shore-485121-i1")
TOPIC_ID = os.environ.get("TOPIC_ID", "forbidden")
BUCKET_NAME = os.environ.get("BUCKET_NAME", "alan-assign2")
SERVICE2_URL = os.environ.get("SERVICE2_URL", "")
DATABASE_URL = os.environ.get("DATABASE_URL", "")

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
ALL_HTTP_METHODS = {"PUT", "POST", "DELETE", "HEAD", "CONNECT", "OPTIONS", "TRACE", "PATCH"}

logging_client = cloud_logging.Client()
logger = logging_client.logger("hw5-service1")
storage_client = storage.Client()
publisher = pubsub_v1.PublisherClient()

Base = declarative_base()
engine = create_engine(DATABASE_URL, pool_pre_ping=True) if DATABASE_URL else None
SessionLocal = sessionmaker(bind=engine) if engine else None


class RequestLog(Base):
    __tablename__ = "request_logs"
    id = Column(Integer, primary_key=True, autoincrement=True)
    country = Column(String(128), nullable=False, default="")
    client_ip = Column(String(64), nullable=False, default="")
    gender = Column(String(32), nullable=False, default="Unknown")
    age = Column(Integer, nullable=True)
    income = Column(String(64), nullable=False, default="Unknown")
    is_banned = Column(Boolean, nullable=False, default=False)
    time_of_day = Column(String(32), nullable=False)
    requested_file = Column(String(256), nullable=False)
    request_time = Column(DateTime(timezone=True), nullable=False)


class FailedRequestLog(Base):
    __tablename__ = "failed_request_logs"
    id = Column(Integer, primary_key=True, autoincrement=True)
    request_time = Column(DateTime(timezone=True), nullable=False)
    requested_file = Column(String(256), nullable=False)
    error_code = Column(Integer, nullable=False)


def init_schema() -> None:
    if not engine:
        logger.log_struct({"message": "DATABASE_URL missing, DB logging disabled"}, severity="WARNING")
        return
    Base.metadata.create_all(bind=engine)


def _first_header(headers, keys, default="") -> str:
    for key in keys:
        value = headers.get(key)
        if value is not None and str(value).strip():
            return str(value).strip()
    return default


def get_request_metadata(req):
    country = _first_header(req.headers, ["X-country", "X-Country"], "")
    client_ip = _first_header(
        req.headers,
        ["X-client-ip", "X-Client-Ip", "X-forwarded-for", "X-Forwarded-For"],
        req.remote_addr or "",
    )
    if "," in client_ip:
        client_ip = client_ip.split(",")[0].strip()

    gender = _first_header(req.headers, ["X-gender", "X-Gender"], "Unknown")
    age_raw = _first_header(req.headers, ["X-age", "X-Age"], "")
    income = _first_header(req.headers, ["X-income", "X-Income"], "Unknown")
    is_banned_hdr = _first_header(req.headers, ["X-is-banned", "X-Is-Banned", "X-banned", "X-Banned"], "").lower()

    age: Optional[int] = None
    if age_raw:
        try:
            age = int(float(age_raw))
        except ValueError:
            age = None

    is_banned = is_banned_hdr in {"1", "true", "yes", "y"} or country in FORBIDDEN_COUNTRIES
    now = datetime.now(timezone.utc)

    return {
        "country": country,
        "client_ip": client_ip,
        "gender": gender,
        "age": age,
        "income": income,
        "is_banned": is_banned,
        "time_of_day": now.strftime("%H:%M:%S"),
        "request_time": now,
    }


def publish_forbidden_event(country: str, requested_file: str) -> None:
    message = f"Forbidden: Export to {country} is prohibited. Path: /{requested_file}"
    topic_path = publisher.topic_path(PROJECT_ID, TOPIC_ID)
    try:
        publisher.publish(topic_path, data=message.encode("utf-8"))
    except Exception as exc:
        logger.log_struct({"message": f"Pub/Sub publish failed: {exc}"}, severity="ERROR")

    if SERVICE2_URL:
        try:
            requests.post(
                SERVICE2_URL + "/forbidden",
                json={"country": country, "path": f"/{requested_file}"},
                timeout=2,
            )
        except Exception:
            pass


def read_from_bucket(requested_file: str) -> tuple[Optional[str], int]:
    filename = requested_file
    if filename.startswith(BUCKET_NAME + "/"):
        filename = filename[len(BUCKET_NAME) + 1 :]
    if not filename.endswith(".html"):
        filename += ".html"

    blob = storage_client.bucket(BUCKET_NAME).blob(f"pages/{filename}")
    if not blob.exists():
        return None, 404
    return blob.download_as_text(), 200


def insert_request_log(metadata: dict, requested_file: str) -> None:
    if not SessionLocal:
        return
    session = SessionLocal()
    try:
        session.add(
            RequestLog(
                country=metadata["country"],
                client_ip=metadata["client_ip"],
                gender=metadata["gender"],
                age=metadata["age"],
                income=metadata["income"],
                is_banned=metadata["is_banned"],
                time_of_day=metadata["time_of_day"],
                requested_file=requested_file,
                request_time=metadata["request_time"],
            )
        )
        session.commit()
    except Exception as exc:
        session.rollback()
        logger.log_struct({"message": f"Insert request log failed: {exc}"}, severity="ERROR")
    finally:
        session.close()


def insert_failed_request(requested_file: str, error_code: int, at_time: datetime) -> None:
    if not SessionLocal:
        return
    session = SessionLocal()
    try:
        session.add(FailedRequestLog(request_time=at_time, requested_file=requested_file, error_code=error_code))
        session.commit()
    except Exception as exc:
        session.rollback()
        logger.log_struct({"message": f"Insert failed request log failed: {exc}"}, severity="ERROR")
    finally:
        session.close()


def log_timing(path: str, metrics: dict) -> None:
    logger.log_struct({"message": "request_timing", "path": path, "timing_seconds": metrics}, severity="INFO")


@app.route("/", defaults={"filename": ""}, methods=list(ALLOWED_METHODS | ALL_HTTP_METHODS))
@app.route("/<path:filename>", methods=list(ALLOWED_METHODS | ALL_HTTP_METHODS))
def handle_request(filename):
    total_start = time.perf_counter_ns()
    timings = {}

    method = request.method
    requested_file = filename or ""

    if method in ALL_HTTP_METHODS:
        now = datetime.now(timezone.utc)
        insert_failed_request(requested_file, 501, now)
        return Response("Not Implemented", status=501)

    if not filename:
        now = datetime.now(timezone.utc)
        insert_failed_request(requested_file, 400, now)
        return Response("No filename provided", status=400)

    header_start = time.perf_counter_ns()
    metadata = get_request_metadata(request)
    timings["header_extraction"] = (time.perf_counter_ns() - header_start) / 1_000_000_000

    if metadata["country"] in FORBIDDEN_COUNTRIES:
        publish_forbidden_event(metadata["country"], requested_file)

        db_start = time.perf_counter_ns()
        insert_request_log(metadata, requested_file)
        insert_failed_request(requested_file, 400, metadata["request_time"])
        timings["db_insert"] = (time.perf_counter_ns() - db_start) / 1_000_000_000

        timings["total"] = (time.perf_counter_ns() - total_start) / 1_000_000_000
        log_timing(f"/{requested_file}", timings)
        return Response("Permission Denied", status=400)

    gcs_start = time.perf_counter_ns()
    content, code = read_from_bucket(requested_file)
    timings["gcs_read"] = (time.perf_counter_ns() - gcs_start) / 1_000_000_000

    db_start = time.perf_counter_ns()
    insert_request_log(metadata, requested_file)
    if code != 200:
        insert_failed_request(requested_file, code, metadata["request_time"])
    timings["db_insert"] = (time.perf_counter_ns() - db_start) / 1_000_000_000

    response_start = time.perf_counter_ns()
    if code == 200:
        response = Response(content, status=200, mimetype="text/html")
    else:
        response = Response("Not Found", status=404)
    timings["response_send"] = (time.perf_counter_ns() - response_start) / 1_000_000_000

    timings["total"] = (time.perf_counter_ns() - total_start) / 1_000_000_000
    log_timing(f"/{requested_file}", timings)
    return response


@app.route("/stats", methods=["GET"])
def stats():
    if not engine:
        return Response("DATABASE_URL is not configured", status=500)

    queries = {
        "success_vs_failure": """
            SELECT
              (SELECT COUNT(*) FROM request_logs) - (SELECT COUNT(*) FROM failed_request_logs) AS successful,
              (SELECT COUNT(*) FROM failed_request_logs) AS unsuccessful
        """,
        "banned_requests": "SELECT COUNT(*) AS banned_requests FROM request_logs WHERE is_banned = TRUE",
        "male_vs_female": """
            SELECT gender, COUNT(*) AS count
            FROM request_logs
            GROUP BY gender
            ORDER BY count DESC
        """,
        "top_5_countries": """
            SELECT country, COUNT(*) AS count
            FROM request_logs
            GROUP BY country
            ORDER BY count DESC
            LIMIT 5
        """,
        "top_age_group": """
            SELECT age_group, count
            FROM (
              SELECT
                CASE
                  WHEN age IS NULL THEN 'Unknown'
                  WHEN age < 18 THEN '0-17'
                  WHEN age BETWEEN 18 AND 24 THEN '18-24'
                  WHEN age BETWEEN 25 AND 34 THEN '25-34'
                  WHEN age BETWEEN 35 AND 44 THEN '35-44'
                  WHEN age BETWEEN 45 AND 54 THEN '45-54'
                  ELSE '55+'
                END AS age_group,
                COUNT(*) AS count
              FROM request_logs
              GROUP BY age_group
            ) x
            ORDER BY count DESC
            LIMIT 1
        """,
        "top_income_group": """
            SELECT income, COUNT(*) AS count
            FROM request_logs
            GROUP BY income
            ORDER BY count DESC
            LIMIT 1
        """,
    }

    lines = []
    with engine.connect() as conn:
        for name, sql in queries.items():
            rows = [dict(row._mapping) for row in conn.execute(text(sql)).fetchall()]
            lines.append(f"{name}: {rows}")
    return Response("\n".join(lines), status=200, mimetype="text/plain")


if __name__ == "__main__":
    init_schema()
    port = int(os.environ.get("PORT", 80))
    app.run(host="0.0.0.0", port=port)
