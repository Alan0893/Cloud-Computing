# CS 528 — Cloud Computing

Coursework for Boston University CS 528. Each `hw*` directory is a standalone assignment, mostly on Google Cloud (GCS, Compute Engine, Cloud Functions, Pub/Sub, Cloud SQL, Dataflow, load balancing, GKE).

## Homework

| Directory | What it did |
|---|---|
| [hw2](./hw2) | Built a synthetic web graph (HTML pages with random links), stored it in GCS, then computed PageRank plus in/out-degree stats over the corpus. |
| [hw3](./hw3) | HTTP Cloud Function that serves pages from GCS, blocks embargoed countries, and publishes forbidden-access events to Pub/Sub. A second subscriber writes those events to a GCS log. |
| [hw4](./hw4) | Same two-service design as HW3, moved onto GCE VMs with IAM, Pub/Sub, a static IP, firewall rules, and a client VM. |
| [hw5](./hw5) | Added Cloud SQL (MySQL) request logging and a `/stats` endpoint. A Cloud Function + Cloud Scheduler stop the database hourly when idle. Load-tested with two concurrent identical-seed clients. |
| [hw6](./hw6) | Normalized HW5 logs into 3NF, then trained models on a GCE VM: IP→country lookup and income prediction. Predictions and metrics go to GCS. |
| [hw7](./hw7) | Apache Beam pipeline (local DirectRunner or Dataflow) over the HTML corpus: top-5 incoming links, outgoing links, and word bigrams. |
| [hw8](./hw8) | Regional HTTP load balancer in front of web VMs in two zones, with health checks and a failover experiment (stop one backend, measure traffic shift, bring it back). |
| [hw9](./hw9) | Containerized the web server and deployed it to GKE Autopilot (2 replicas) behind a Kubernetes LoadBalancer, using Workload Identity for GCS and Pub/Sub. |

## Details

### hw2 — PageRank on GCS

`generate-content.py` creates thousands of linked HTML pages. `pagerank.py` downloads them in parallel from a GCS bucket, builds the adjacency list, reports incoming/outgoing link statistics, and iterates PageRank until convergence.

### hw3 — Serverless web server + Pub/Sub

Service 1 is a Cloud Function: GET-only HTML serving from GCS, 501 for other methods, 400 for embargoed `X-country` values (event published to Pub/Sub), 404 if the page is missing. Service 2 is a long-running Pub/Sub subscriber that appends forbidden-access messages to GCS.

### hw4 — Same services on Compute Engine

`setup.sh` provisions three VMs (web server, HTTP client, reporter), service accounts, Pub/Sub, and a static IP. The Flask web server still enforces country export controls and serves pages from GCS; the reporter consumes Pub/Sub and also accepts HTTP callbacks.

### hw5 — Cloud SQL logging and cost control

Extends HW4 so every request is logged to MySQL (`request_logs` / `failed_request_logs`) with client metadata (country, IP, gender, age, income). `/stats` answers questions like banned-request count and top countries. `cloud_function/` plus Cloud Scheduler set the instance activation policy to `NEVER` on an hourly cadence so the database is not left running.

### hw6 — 3NF + ML on request logs

`schema_3nf.sql` / `normalize_schema.py` split denormalized HW5 rows into `countries`, `ip_addresses`, `demographics`, and `request_events`. `train_models.py` trains an IP→country memorization model and a HistGradientBoosting income classifier, then uploads test predictions and accuracy metrics to GCS. `setup.sh` spins up a training VM, runs the job, and tears the VM down.

### hw7 — Apache Beam analytics

`pipeline.py` reads the HTML corpus and emits top-5 incoming links, outgoing links, and word bigrams. It runs locally (`BundleBasedDirectRunner`) or on Dataflow against `gs://` paths.

### hw8 — Multi-zone load balancing and failover

Two web VMs in `us-west1-a` and `us-west1-b` sit behind a regional TCP/HTTP load balancer with instance groups and `/health` checks. Responses include `X-Server-Zone`. `run_failover_experiment.sh` stops one backend, records where traffic goes, then restarts it. `lb_client.py` is the request generator.

### hw9 — GKE Autopilot

The web server is a Docker image built with Cloud Build into Artifact Registry. `setup.sh` creates a GKE Autopilot cluster, applies a 2-replica Deployment and LoadBalancer Service, and binds a Kubernetes service account to a GCP service account (Workload Identity). Pods serve GCS pages, publish forbidden events to Pub/Sub, and return `X-Pod-Name`. A reporter VM and client VM complete the same two-service pattern as earlier homeworks.
