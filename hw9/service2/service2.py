"""HW9 service 2 — runs on a VM, prints forbidden-country requests.
"""

import os
import sys
import time

from google.cloud import pubsub_v1

PROJECT_ID = os.environ.get("PROJECT_ID", "")
SUBSCRIPTION_ID = os.environ.get("SUBSCRIPTION_ID", "hw9-forbidden-sub")


def callback(message):
    text = message.data.decode("utf-8")
    print(f"[FORBIDDEN] {text}", flush=True)
    message.ack()


def main():
    if not PROJECT_ID:
        print("PROJECT_ID env var must be set", file=sys.stderr, flush=True)
        sys.exit(1)

    subscriber = pubsub_v1.SubscriberClient()
    subscription_path = subscriber.subscription_path(PROJECT_ID, SUBSCRIPTION_ID)

    print(f"HW9 service2 listening on {subscription_path}", flush=True)
    streaming_pull_future = subscriber.subscribe(subscription_path, callback=callback)

    with subscriber:
        try:
            streaming_pull_future.result()
        except KeyboardInterrupt:
            streaming_pull_future.cancel()
            streaming_pull_future.result()
        except Exception as exc:
            print(f"Subscriber error: {exc}", flush=True)
            streaming_pull_future.cancel()
            time.sleep(2)
            raise


if __name__ == "__main__":
    main()
