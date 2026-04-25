#!/usr/bin/env python3

import argparse
import csv
import random
import sys
import time
from collections import Counter
from datetime import datetime, timezone
from pathlib import Path
from typing import Optional
from urllib import error, request

DEFAULT_ZONE_HEADER = "X-Server-Zone"
DEFAULT_PATHS = ["index.html"]
CLIENT_IPS = ["34.12.10.11", "34.12.10.12", "34.12.10.13", "34.12.10.14"]
GENDERS = ["female", "male", "nonbinary"]
INCOMES = ["low", "medium", "high"]


def parse_args():
    parser = argparse.ArgumentParser(
        description="Send deterministic GET requests to the load balancer and print backend zones."
    )
    parser.add_argument("--server", required=True, help="Base server URL, for example http://34.10.10.10")
    parser.add_argument("--path", default="index.html", help="Request path or filename to fetch")
    parser.add_argument(
        "--paths",
        help="Comma-separated list of request paths. If set, one path is chosen per request using --seed.",
    )
    parser.add_argument("--seed", type=int, default=0, help="Random seed for deterministic request selection")
    parser.add_argument(
        "--requests",
        type=int,
        default=0,
        help="Number of requests to send. Use 0 to run until interrupted.",
    )
    parser.add_argument("--interval", type=float, default=1.0, help="Delay between requests in seconds")
    parser.add_argument("--timeout", type=float, default=3.0, help="Per-request timeout in seconds")
    parser.add_argument("--country", default="United States", help="Value for the X-country header")
    parser.add_argument("--client-ip", help="Value for the X-client-ip header")
    parser.add_argument("--gender", help="Value for the X-gender header")
    parser.add_argument("--age", type=int, help="Value for the X-age header")
    parser.add_argument("--income", help="Value for the X-income header")
    parser.add_argument("--csv", help="Optional CSV log path for per-request results")
    parser.add_argument("--print-body", action="store_true", help="Print the response body")
    parser.add_argument(
        "--zone-header",
        default=DEFAULT_ZONE_HEADER,
        help=f"Response header containing the backend zone (default: {DEFAULT_ZONE_HEADER})",
    )
    return parser.parse_args()


def normalize_base_url(server: str) -> str:
    if not server.startswith(("http://", "https://")):
        server = f"http://{server}"
    return server.rstrip("/")


def normalize_path(path: str) -> str:
    cleaned = path.strip()
    if not cleaned:
        return ""
    return cleaned.lstrip("/")


def build_url(base_url: str, path: str) -> str:
    normalized_path = normalize_path(path)
    if not normalized_path:
        return f"{base_url}/"
    return f"{base_url}/{normalized_path}"


def format_ts(ts: datetime) -> str:
    return ts.isoformat(timespec="seconds")


def choose_paths(args) -> list[str]:
    if args.paths:
        paths = [normalize_path(value) for value in args.paths.split(",")]
        return [path for path in paths if path]

    normalized = normalize_path(args.path)
    if normalized:
        return [normalized]

    return DEFAULT_PATHS.copy()


def build_headers(args, rng: random.Random) -> dict[str, str]:
    return {
        "X-country": args.country,
        "X-client-ip": args.client_ip or rng.choice(CLIENT_IPS),
        "X-gender": args.gender or rng.choice(GENDERS),
        "X-age": str(args.age if args.age is not None else rng.randint(18, 70)),
        "X-income": args.income or rng.choice(INCOMES),
    }


def open_csv_writer(csv_path: Optional[str]):
    if not csv_path:
        return None, None

    output_path = Path(csv_path)
    output_path.parent.mkdir(parents=True, exist_ok=True)
    handle = output_path.open("w", newline="", encoding="utf-8")
    writer = csv.writer(handle)
    writer.writerow(["timestamp", "request_id", "url", "status", "zone", "latency_ms", "error"])
    return handle, writer


def print_summary(total_sent: int, successes: int, failures: int, zone_counts: Counter, error_counts: Counter):
    print("")
    print("Summary")
    print(f"  total_requests={total_sent}")
    print(f"  successes={successes}")
    print(f"  failures={failures}")

    if zone_counts:
        print("  zone_distribution")
        for zone, count in sorted(zone_counts.items()):
            ratio = count / successes if successes else 0.0
            print(f"    {zone}: {count} ({ratio:.2%})")

    if error_counts:
        print("  errors")
        for err, count in sorted(error_counts.items()):
            print(f"    {err}: {count}")


def main():
    args = parse_args()
    rng = random.Random(args.seed)
    base_url = normalize_base_url(args.server)
    paths = choose_paths(args)
    csv_handle, csv_writer = open_csv_writer(args.csv)

    total_sent = 0
    successes = 0
    failures = 0
    zone_counts = Counter()
    error_counts = Counter()

    try:
        while args.requests == 0 or total_sent < args.requests:
            path = rng.choice(paths)
            url = build_url(base_url, path)
            headers = build_headers(args, rng)
            timestamp = datetime.now(timezone.utc)
            started_at = time.monotonic()
            total_sent += 1

            req = request.Request(url, headers=headers, method="GET")
            try:
                with request.urlopen(req, timeout=args.timeout) as response:
                    body = response.read().decode("utf-8", errors="replace")
                    latency_ms = (time.monotonic() - started_at) * 1000
                    status = response.status
                    zone = response.headers.get(args.zone_header, "missing")
                    zone_counts[zone] += 1
                    successes += 1

                    print(
                        f"{format_ts(timestamp)} request={total_sent} status={status} "
                        f"zone={zone} latency_ms={latency_ms:.1f} path={path}"
                    )
                    if args.print_body:
                        print(body)

                    if csv_writer:
                        csv_writer.writerow(
                            [format_ts(timestamp), total_sent, url, status, zone, f"{latency_ms:.1f}", ""]
                        )
                        csv_handle.flush()

            except error.HTTPError as exc:
                latency_ms = (time.monotonic() - started_at) * 1000
                failures += 1
                error_counts[f"http_{exc.code}"] += 1
                zone = exc.headers.get(args.zone_header, "missing")
                print(
                    f"{format_ts(timestamp)} request={total_sent} status={exc.code} "
                    f"zone={zone} latency_ms={latency_ms:.1f} path={path}"
                )

                if csv_writer:
                    csv_writer.writerow(
                        [format_ts(timestamp), total_sent, url, exc.code, zone, f"{latency_ms:.1f}", ""]
                    )
                    csv_handle.flush()

            except Exception as exc:
                latency_ms = (time.monotonic() - started_at) * 1000
                failures += 1
                error_name = exc.__class__.__name__
                error_counts[error_name] += 1
                print(
                    f"{format_ts(timestamp)} request={total_sent} error={error_name} "
                    f"latency_ms={latency_ms:.1f} path={path} detail={exc}"
                )

                if csv_writer:
                    csv_writer.writerow(
                        [format_ts(timestamp), total_sent, url, "", "", f"{latency_ms:.1f}", f"{error_name}: {exc}"]
                    )
                    csv_handle.flush()

            time.sleep(args.interval)

    except KeyboardInterrupt:
        print("")
        print("Interrupted by user.", file=sys.stderr)
    finally:
        if csv_handle:
            csv_handle.close()

    print_summary(total_sent, successes, failures, zone_counts, error_counts)


if __name__ == "__main__":
    main()
