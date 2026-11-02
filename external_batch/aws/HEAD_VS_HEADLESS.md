# OpenStudio Server AWS Batch: Architecture Guide (Direct vs. Step Functions vs. Head Node)

## Overview

When scaling OpenStudio simulations to hundreds, thousands, or hundreds of thousands of datapoints on AWS Batch, four primary operational topologies are available:

1. **Option A: Direct Headless External Batch (Serverless CLI)**: Direct S3 package push + direct Batch array submission via `submit_batch.rb`, with client-side polling (`sync_results.rb` or `viewer/index.html`).
2. **Option A+: Step Functions Headless External Batch (Serverless State Machine)**: Pure fire-and-forget submission to an AWS Step Functions state machine (`external_batch/aws/orchestration/state_machine.asl.json`). The state machine manages array job dispatch (`.sync`), Spot failure retries, error budgets, automated cloud-side post-processing (`aggregate_csv.rb`), and optional SNS completion notifications.
3. **Option B+: Step Functions Cloud Head Node (Hybrid Fire-and-Forget)**: OpenStudio Server (mongod + Rails API/UI) running on an EC2 instance (`t3.large`/`c6i.xlarge`), dispatching external batch runs directly to Step Functions. The client laptop detaches in seconds; upon completion, EventBridge delivers a webhook callback (`POST /analyses/:id/complete_external_batch`) to load summary metrics into Rails without serial MongoDB document ingestion.
4. **Option B: Traditional Cloud Head Node (Full Ingestion Server)**: OpenStudio Server running on EC2, coordinating workers with continuous local background worker polling and serial BSON document ingestion into MongoDB.

This document details the architectural trade-offs, operational workflows, performance characteristics, and empirical benchmarks across all four options.

---

## Architecture Topologies

```
+--------------------------------------------------------------------------------------------------+
| OPTION A: DIRECT HEADLESS EXTERNAL BATCH (Serverless CLI)                                        |
|                                                                                                  |
|  [ Workstation / CI ]                                                                            |
|          |                                                                                       |
|   (package & submit)                                                                             |
|          v                                                                                       |
|   +--------------+      submit array job       +--------------------+                            |
|   |   S3 Bucket  | <-------------------------> |  AWS Batch Fleet   |                            |
|   |  (runs/...)  |                             | (Fargate Spot/EC2) |                            |
|   +--------------+ <-------------------------> +--------------------+                            |
|          ^             download chunk &                |                                         |
|          |             upload results                  |                                         |
|  +-------------------+                                 v                                         |
|  | Lightweight HTML  |                      CloudWatch Log Streams                               |
|  | Viewer / CSV Sync |                                                                           |
|  +-------------------+                                                                           |
+--------------------------------------------------------------------------------------------------+

+--------------------------------------------------------------------------------------------------+
| OPTION A+: STEP FUNCTIONS HEADLESS EXTERNAL BATCH (Fire-and-Forget Serverless)                   |
|                                                                                                  |
|  [ Workstation / CI ]                                                                            |
|          |                                                                                       |
|   (push package & start execution)  <--- DETACH IN ~12 SECONDS (No active client polling)       |
|          v                                                                                       |
|  +-----------------------------------------------------------------------------------------+     |
|  | AWS Step Functions State Machine (osaf-batch-orchestrator)                              |     |
|  |                                                                                         |     |
|  |   [Validate Package] -> [Check Chunk Count] -> [Submit Array Job (.sync)]               |     |
|  |                                                        |                                |     |
|  |                                                        v                                |     |
|  |   [Send SNS] <- [Run Finalizer (aggregate_csv)] <- [Evaluate Failure Threshold]         |     |
|  +-----------------------------------------------------------------------------------------+     |
|          |                             |                             |                           |
|          v                             v                             v                           |
|   +--------------+            +--------------------+         +-------------------+               |
|   |  S3 Storage  |            |  AWS Batch Fleet   |         |    Amazon SNS     |               |
|   | (runs/...    |            | (Simulation Chunks |         |   (Notification   |               |
|   |  & final CSV)|            |  + Finalizer Task) |         |    on Complete)   |               |
|   +--------------+            +--------------------+         +-------------------+               |
+--------------------------------------------------------------------------------------------------+

+--------------------------------------------------------------------------------------------------+
| OPTION B+: STEP FUNCTIONS CLOUD HEAD NODE (Hybrid Fire-and-Forget)                               |
|                                                                                                  |
|  [ User Laptop / Browser ]                                                                       |
|          |                                                                                       |
|    (Submit Analysis)   <--- DETACH LAPTOP IN < 30 SECONDS (Walk away for 24-36 hrs)              |
|          v                                                                                       |
|  +-----------------------------------------------------------------------------------------+     |
|  | EC2 Head Node (OpenStudio Server)                                                       |     |
|  |  - Packages chunks to S3                                                                |     |
|  |  - Triggers Step Functions State Machine                                                |     |
|  +-----------------------------------------------------------------------------------------+     |
|          |                                             ^                                         |
|   (start execution)                             (EventBridge /                                   |
|          v                                       Webhook callback)                               |
|  +---------------------------------------+             |                                         |
|  | AWS Step Functions State Machine      |             |                                         |
|  |  - Coordinates 450,000 Batch jobs     |             |                                         |
|  |  - Runs Cloud Finalizer (Parquet/CSV) |-------------+                                         |
|  +---------------------------------------+                                                       |
|          |                                                                                       |
|          v                                                                                       |
|   +--------------+      submit array job       +--------------------+                            |
|   |   S3 Bucket  | <-------------------------> |  AWS Batch Fleet   |                            |
|   | (runs/ & CSV)|                             | (Fargate Spot/EC2) |                            |
|   +--------------+ <-------------------------> +--------------------+                            |
+--------------------------------------------------------------------------------------------------+
```

---

## Detailed Model Analysis

### Option A: Direct Headless External Batch (Serverless CLI)
Direct S3 staging and Batch dispatch driven by `submit_batch.rb`.
- **Client Detach**: ~13.8 seconds.
- **Client Responsibility**: Client workstation or CI runner must remain connected or periodically re-run `sync_results.rb` to pull results down for local aggregation.
- **Cost**: $0 idle cost.

### Option A+: Step Functions Headless External Batch
Cloud-native state machine coordination (`submit_batch.rb --step-functions <ARN>`).
- **Client Detach**: **~12.5 seconds** (fire-and-forget). Client immediately returns execution ARN and exits. Workstation can be shut down.
- **Cloud-Native Resilience**: Built-in ASL `Retry` policies with exponential backoff on `Batch.ServerException` or Spot reclaims.
- **Failure Threshold / Error Budget**: Configurable gate (`AllowPartialFailure`); allows partial batch completion (e.g. 95%+ success rate) to proceed directly to post-processing.
- **Automated Cloud Finalizer**: The state machine launches a containerized finalizer task (`task_wrapper.sh` with `BATCH_TASK_MODE=finalize`) that downloads S3 results, executes `aggregate_csv.rb`, and writes `aggregated_measure_attributes.csv` directly into S3.
- **Notification**: Emits SNS notifications or EventBridge events upon campaign completion.

### Option B+: Step Functions Cloud Head Node (Hybrid Fire-and-Forget)
Combines the central OpenStudio Server Web UI with Step Functions serverless execution.
- **Zero Client Machine Dependency**: The user submits the analysis via the Web UI or curl from their laptop in seconds, and can close their laptop immediately.
- **Eliminates 28.5-Hour Ingestion Bottleneck**: When the 450,000 simulations complete, Step Functions runs the finalizer task in S3 and notifies the Head Node via an EventBridge webhook. The Head Node only registers the summary metrics and links to the S3 dataset, bypassing serial MongoDB document insertion.
- **Central Web UI**: Project managers and team members can view the analysis progress and download results at `http://<head-node>:8080/analyses/<id>`.

### Option B: Traditional Cloud Head Node (Full Ingestion Server)
Hosts OpenStudio Server on an EC2 instance with serial background worker ingestion.
- **Database Scaling Bottleneck**: MongoDB serial ingestion requires ~22.5 seconds per 100 datapoints. At 450,000 runs, this translates to **~28.5 hours** of continuous database writes and ~11.6 GB of BSON documents.
- **Cost**: Persistent EC2 baseline ($60–$150/month) even when idle.

---

## Four-Way Trade-Off Summary

| Attribute | Option A: Direct Headless | Option A+: Step Functions Headless | Option B+: Step Functions Head Node | Option B: Traditional Head Node |
| :--- | :--- | :--- | :--- | :--- |
| **Primary Use Case** | Interactive CLI sweeps, quick test batches | Massive production runs (10k–500k+), fire-and-forget CI/CD | Production runs requiring Web UI (10k–500k+) | Interactive modeling, adaptive algorithms (NSGA-II) |
| **Client Requirement** | Must poll until batch completes | **Zero client attachment** (instant detach) | **Zero client attachment** (instant detach) | Must stay connected to Rails |
| **Client Detach Time** | 13.85 seconds | **12.50 seconds** (live S3) | **35.95 seconds** (live S3) | 35.95 seconds |
| **Cloud State Machine Overhead**| 0.0 seconds | **~0.80 seconds** (negligible) | **~0.80 seconds** (negligible) | N/A (Server / Resque process) |
| **Post-Processing Execution** | Client-side (`aggregate_csv.rb`) | **Automated in Cloud** (`task_wrapper.sh finalize`) | **Automated in Cloud** (`task_wrapper.sh finalize`) | Head Node Ingester into MongoDB |
| **Post-Processing Wall Time** | 0.18s local execution | **0.42s container task** in S3 | **0.42s container task** in S3 | 22.47s MongoDB serial write |
| **Database Bloat (100 runs)** | 0.00 MB | **0.00 MB** | **< 0.05 MB** (summary link) | +2.58 MB (+11.6 GB at 450k runs) |
| **Spot Retry Handling** | Client logic / manual retry | **Cloud ASL native Retry & Error Budget** | **Cloud ASL native Retry & Error Budget** | Ingester re-queuing |
| **Completion Notification** | Terminal output | **Amazon SNS / EventBridge rule** | **EventBridge webhook to Rails Web UI** | Web UI / Email |
| **Idle Infrastructure Cost** | **$0.00 / month** | **$0.00 / month** | **$0.00 / month** (Ephemeral) | **$0.00 / month** (Ephemeral) |
| **Active Head Node Cost (3 runs/mo)**| **$0.00 / month** | **$0.00 / month** | **~$0.93 – $1.85 / month** | **~$2.67 – $5.27 / month** |

---

## Scaled Projections: 100,000-Simulation Campaign Analysis

*Sizing Baseline: 100,000 annual building energy simulations, 1,000 chunks of 100 datapoints each, AWS Batch `FARGATE_SPOT` (1 vCPU, 8 GB RAM per container) capped at 256 concurrent vCPUs (Terraform default `max_vcpus = 256`), assuming **3 simulation campaigns per month**.*

| Metric | Option A: Direct Headless | Option A+: Step Functions Headless | Option B+: Step Functions Head Node (Ephemeral) | Option B: Traditional Head Node (Ephemeral) |
| :--- | :--- | :--- | :--- | :--- |
| **Client Submission & Detach Time** | **~3–4 minutes** | **~3–4 minutes** (Fire-and-Forget) | **< 30 seconds** (Laptop closes) | **< 30 seconds** (Laptop closes) |
| **Client Machine Online Need** | **3.2 hours** (must poll/sync) | **None (0 min)** | **None (0 min)** | **None (0 min)** |
| **Batch Fleet Runtime (100k sims)** | **~3.2 hours** (at 256 vCPUs) | **~3.2 hours** (at 256 vCPUs) | **~3.2 hours** (at 256 vCPUs) | **~3.2 hours** (at 256 vCPUs) |
| **State Machine Overhead** | 0.00s | **~1.5 seconds** (< 0.01%) | **~1.5 seconds** (< 0.01%) | N/A (Server background process) |
| **Database Ingestion Time** | **0.00s** (Serverless) | **0.00s** (Serverless) | **< 1.0s** (S3 summary webhook) | **~6.24 hours** (Serial MongoDB write) |
| **Total Campaign Process Time** | **~3.2 hours** | **~3.2 hours** | **~3.3 hours** | **~9.5 hours** (3.2h batch + 6.2h ingest) |
| **MongoDB Storage Growth (per run)** | **0.00 MB** | **0.00 MB** | **< 2.0 MB** (summary KPIs & S3 URI) | **+2.58 GB** BSON data (+3.2 GB on disk) |
| **Final Result Aggregation** | ~45–60s (Client-side) | **~45–60s** (Cloud container in S3) | **~45–60s** (Cloud container in S3) | ~5–10 min (Database export query) |
| **Monitoring Interface** | HTML viewer (`viewer/index.html`) | Step Functions Console + HTML viewer | Rails Web UI (`:8080`) + HTML viewer | Rails Web UI (`:8080`) |
| **Head Node Runtime (per run)** | 0.0 hours | 0.0 hours | **~3.5 hours** (Terminated after run) | **~10.0 hours** (Batch + Ingestion phase) |
| **Head Node Compute Cost (3 runs/mo)**| **$0.00 / month** | **$0.00 / month** | **$0.87 – $1.79 / month** | **$2.50 – $5.10 / month** |
| **Head Node Ephemeral Storage Cost** | **$0.00 / month** | **$0.00 / month** | **$0.06 / month** (50GB gp3 prorated) | **$0.17 / month** (50GB gp3 prorated) |
| **Total Head Node Cost (3 runs/mo)** | **$0.00 / month** | **$0.00 / month** | **~$0.93 – $1.85 / month** | **~$2.67 – $5.27 / month** |
| **AWS Batch Compute Cost (3 runs/mo)**| **~$42.50 / month** | **~$42.50 / month** | **~$42.50 / month** | **~$42.50 / month** |

---

## Empirical Benchmark Reference (100 Simulations)

*Benchmark Configuration: SEB 2013 Latin Hypercube Sampling (LHS), 100 datapoints across 10 parallel chunks, AWS Batch `FARGATE_SPOT` (1 vCPU, 8 GB per container task) in `us-east-1` (Account `846898690207`).*

| Metric | Option A: Direct Headless | Option A+: Step Functions Headless | Option B+: Step Functions Head Node | Option B: Traditional Head Node |
| :--- | :--- | :--- | :--- | :--- |
| **Sampling Time** | 1.91s | 1.91s | 0.26s | 0.26s |
| **Packaging Time** | 0.31s | 0.31s | 0.28s | 0.28s |
| **S3 Upload & Submission Time** | 11.48s | 10.13s | 33.58s | 33.58s |
| **Total Client Detach Time** | **13.85s** | **12.50s** (live S3) / **2.51s** | **35.95s** (live S3) / **2.78s** | **35.95s** |
| **State Machine Transition Overhead** | N/A | **~0.8s** | **~0.8s** | N/A |
| **Batch Simulation Fleet Time** | 4 min 54 sec | 4 min 54 sec | 4 min 54 sec | 4 min 54 sec |
| **Cloud-Side Finalizer Time** | N/A (Local script) | **0.42s** (`aggregate_csv.rb`) | **0.42s** (`aggregate_csv.rb`) | 22.47s (Mongo Ingest) |
| **Client Machine Online Need** | Full 5 minutes | **12.5 seconds only** | **35 seconds only** | Full 5.5 minutes |
| **Aggregated Dataset Produced** | Local CSV | Direct in S3 (`runs/.../results/*.csv`) | Direct in S3 (`runs/.../results/*.csv`) | MongoDB Query Export |

---

## Provisioning and Deployment

### 1. Provisioning Headless Infrastructure (Option A)
```bash
cd external_batch/aws/infra
terraform init
terraform apply -var region=us-east-1 -var bucket_name=osaf-batch-846898690207
```

### 2. Provisioning Step Functions Orchestration (Option A+ / Option B+)
```bash
cd external_batch/aws/infra
terraform apply \
  -var region=us-east-1 \
  -var bucket_name=osaf-batch-846898690207 \
  -var enable_step_functions=true
```

In enterprise accounts with pre-provisioned IAM roles:
```bash
terraform apply \
  -var-file=nrel-846898690207.tfvars \
  -var enable_step_functions=true \
  -var existing_step_functions_role_arn=arn:aws:iam::846898690207:role/role-batch-service-179d
```

### 3. Provisioning Cloud Head Node (Option B / Option B+)
```bash
cd external_batch/aws/infra
terraform apply \
  -var region=us-east-1 \
  -var bucket_name=osaf-batch-846898690207 \
  -var enable_head_node=true \
  -var head_node_instance_type=t3.large
```
