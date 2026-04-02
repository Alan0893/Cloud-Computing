#!/usr/bin/env python3
"""Create HW5 Cloud SQL schema if it does not exist."""

import os
import time

from sqlalchemy import create_engine, text


def wait_for_db(engine, retries=30, sleep_seconds=2):
    for _ in range(retries):
        try:
            with engine.connect() as conn:
                conn.execute(text("SELECT 1"))
            return True
        except Exception:
            time.sleep(sleep_seconds)
    return False


def main():
    database_url = os.environ.get("DATABASE_URL", "").strip()
    if not database_url:
        raise RuntimeError("DATABASE_URL is required for setup_schema.py")

    engine = create_engine(database_url, pool_pre_ping=True)
    if not wait_for_db(engine):
        raise RuntimeError("Database did not become ready in time")

    ddl = [
        """
        CREATE TABLE IF NOT EXISTS request_logs (
            id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
            country VARCHAR(128) NOT NULL DEFAULT '',
            client_ip VARCHAR(64) NOT NULL DEFAULT '',
            gender VARCHAR(32) NOT NULL DEFAULT 'Unknown',
            age INT NULL,
            income VARCHAR(64) NOT NULL DEFAULT 'Unknown',
            is_banned TINYINT(1) NOT NULL DEFAULT 0,
            time_of_day VARCHAR(32) NOT NULL,
            requested_file VARCHAR(256) NOT NULL,
            request_time DATETIME(6) NOT NULL,
            PRIMARY KEY (id)
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4
        """,
        """
        CREATE TABLE IF NOT EXISTS failed_request_logs (
            id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
            request_time DATETIME(6) NOT NULL,
            requested_file VARCHAR(256) NOT NULL,
            error_code INT NOT NULL,
            PRIMARY KEY (id)
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4
        """,
    ]

    with engine.begin() as conn:
        for stmt in ddl:
            conn.execute(text(stmt))

        req_exists = conn.execute(
            text(
                """
                SELECT EXISTS (
                    SELECT 1 FROM information_schema.tables
                    WHERE table_schema = DATABASE() AND table_name = 'request_logs'
                )
                """
            )
        ).scalar()
        fail_exists = conn.execute(
            text(
                """
                SELECT EXISTS (
                    SELECT 1 FROM information_schema.tables
                    WHERE table_schema = DATABASE() AND table_name = 'failed_request_logs'
                )
                """
            )
        ).scalar()

    print(f"request_logs_exists={bool(req_exists)}")
    print(f"failed_request_logs_exists={bool(fail_exists)}")
    print("Schema setup complete.")


if __name__ == "__main__":
    main()
