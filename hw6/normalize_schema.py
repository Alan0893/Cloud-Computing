#!/usr/bin/env python3
"""Create 3NF schema and migrate data from HW5 tables."""

import os
from pathlib import Path

from sqlalchemy import create_engine, text


def read_sql(file_name: str) -> str:
    here = Path(__file__).resolve().parent
    return (here / file_name).read_text(encoding="utf-8")


def main() -> None:
    database_url = os.environ.get("DATABASE_URL", "").strip()
    if not database_url:
        raise RuntimeError("DATABASE_URL is required")

    engine = create_engine(database_url, pool_pre_ping=True)
    schema_sql = read_sql("schema_3nf.sql")
    migrate_sql = read_sql("migrate_to_3nf.sql")

    with engine.begin() as conn:
        # Create normalized tables if missing.
        for stmt in [s.strip() for s in schema_sql.split(";") if s.strip()]:
            conn.execute(text(stmt))

        # Idempotent migration: reload fact tables each run.
        conn.execute(text("TRUNCATE TABLE request_events RESTART IDENTITY CASCADE"))
        conn.execute(text("TRUNCATE TABLE failed_request_events RESTART IDENTITY"))

        for stmt in [s.strip() for s in migrate_sql.split(";") if s.strip()]:
            conn.execute(text(stmt))

        # Validate HW assumption: each IP should map to one country.
        ip_conflicts = conn.execute(
            text(
                """
                SELECT COUNT(*) FROM (
                    SELECT client_ip
                    FROM request_logs
                    GROUP BY client_ip
                    HAVING COUNT(DISTINCT country) > 1
                ) t
                """
            )
        ).scalar_one()

        counts = {
            "countries": conn.execute(text("SELECT COUNT(*) FROM countries")).scalar_one(),
            "ip_addresses": conn.execute(text("SELECT COUNT(*) FROM ip_addresses")).scalar_one(),
            "demographics": conn.execute(text("SELECT COUNT(*) FROM demographics")).scalar_one(),
            "request_events": conn.execute(text("SELECT COUNT(*) FROM request_events")).scalar_one(),
            "failed_request_events": conn.execute(text("SELECT COUNT(*) FROM failed_request_events")).scalar_one(),
        }

    print(f"ip_conflicts_in_source={ip_conflicts}")
    for name, value in counts.items():
        print(f"{name}={value}")
    print("3NF schema setup and migration complete.")


if __name__ == "__main__":
    main()
