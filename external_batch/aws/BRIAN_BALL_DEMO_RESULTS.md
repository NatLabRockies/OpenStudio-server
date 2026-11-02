# OpenStudio Server External Batch Architecture: Side-by-Side Demo & Findings

**To:** Brian Ball, OpenStudio Server Architect & External Batch Author  
**From:** OpenStudio Server & AWS Batch Modernization Team  
**Date:** October 21, 2026  
**Subject:** Empirical Evaluation & 100,000-Simulation Projections: Direct Headless (Option A) vs. Step Functions Headless (Option A+) vs. Step Functions Head Node (Option B+) vs. Traditional Head Node (Option B)

---

## Executive Summary

We have verified and run OpenStudio Server simulations on AWS Batch in account `846898690207` (`us-east-1`) using OpenStudio 3.10.0 / 3.11.0 on Fargate Spot (`osaf-batch-ce`, `osaf-batch-queue`).

To provide concrete empirical data for the OpenStudio Server roadmap and large-scale modeling campaigns (such as generating 100,000 to 450,000 building energy simulations for 179D surrogate models), we evaluated four deployment operational models:

1. **Option A: Direct Headless External Batch (Serverless CLI)**: Direct S3 staging, pure Ruby CLI dispatch (`submit_batch.rb`), Fargate Spot container execution (`run_chunk.rb`), and client-side monitoring via a zero-dependency static HTML viewer (`viewer/index.html`).
2. **Option A+: Step Functions Headless External Batch (Cloud-Native Serverless)**: Fire-and-forget submission to an AWS Step Functions state machine (`external_batch/aws/orchestration/state_machine.asl.json`). Coordinates AWS Batch array jobs (`.sync`), manages Spot retry policies and error budgets, executes automated cloud-side post-processing (`aggregate_csv.rb`), and emits optional SNS completion alerts.
3. **Option B+: Step Functions Cloud Head Node (Ephemeral Fire-and-Forget)**: Ephemeral EC2 Head Node submits the analysis package to Step Functions, detaching the client laptop immediately (< 30 seconds). Step Functions coordinates array runs and cloud aggregation, then triggers an EventBridge webhook callback (`POST /analyses/:id/complete_external_batch`) to complete the analysis on the Head Node without serial MongoDB ingestion. The Head Node runs only for the duration of the campaign and is then terminated.
4. **Option B: Traditional Cloud Head Node (Full Ingestion Server)**: OpenStudio Server (mongod + Rails API/UI + ingester) hosted on an ephemeral EC2 instance (`t3.large`/`c6i.xlarge`), running continuous local ingester loops inserting raw BSON documents into MongoDB for the entire duration of the run and ingestion phase.

All models achieved a **100% simulation success rate** across empirical runs.

---

## 1. Scaled Projections: 100,000-Simulation Campaign Analysis

*Sizing Baseline: 100,000 annual building energy simulations, 1,000 chunks of 100 datapoints each, AWS Batch `FARGATE_SPOT` (1 vCPU, 8 GB RAM per container) capped at 256 concurrent vCPUs (Terraform default `max_vcpus = 256`), assuming **3 simulation campaigns per month**.*

| Metric | Option A: Direct Headless | Option A+: Step Functions Headless | Option B+: Step Functions Head Node (Ephemeral) | Option B: Traditional Head Node (Ephemeral) | Scaling Analysis / Empirical Finding |
| :--- | :--- | :--- | :--- | :--- | :--- |
| **Client Submission & Detach Time** | **~3–4 minutes** | **~3–4 minutes** (Fire-and-Forget) | **< 30 seconds** (Laptop closes) | **< 30 seconds** (Laptop closes) | **Options A+ and B+ free the client laptop completely**; user disconnects immediately |
| **Client Machine Online Need** | **3.2 hours** (must poll/sync) | **None (0 min)** | **None (0 min)** | **None (0 min)** | Client laptop does not need to stay online for the 3+ hour run |
| **Batch Fleet Runtime (100k sims)** | **~3.2 hours** (at 256 vCPUs) | **~3.2 hours** (at 256 vCPUs) | **~3.2 hours** (at 256 vCPUs) | **~3.2 hours** (at 256 vCPUs) | ~20s average per simulation = 555.5 vCPU-hours |
| **State Machine Overhead** | 0.00s | **~1.5 seconds** (< 0.01%) | **~1.5 seconds** (< 0.01%) | N/A (Server background process) | Step Functions transition latency is completely negligible |
| **Database Ingestion Time** | **0.00s** (Serverless) | **0.00s** (Serverless) | **< 1.0s** (S3 summary webhook) | **~6.24 hours** (Serial MongoDB write) | At 4.45 dp/s, traditional Mongo ingest adds 6.24 hrs of continuous database writes |
| **Total Campaign Process Time** | **~3.2 hours** | **~3.2 hours** | **~3.3 hours** | **~9.5 hours** (3.2h batch + 6.2h ingest) | **Option B+ completes 3x faster than traditional Head Node** |
| **MongoDB Storage Growth (per run)** | **0.00 MB** | **0.00 MB** | **< 2.0 MB** (summary KPIs & S3 URI) | **+2.58 GB** BSON data (+3.2 GB on disk) | 3 runs/month in Option B bloat Mongo by **+7.74 GB/mo** of raw BSON data |
| **Final Result Aggregation** | ~45–60s (Client-side) | **~45–60s** (Cloud container in S3) | **~45–60s** (Cloud container in S3) | ~5–10 min (Database export query) | Automated cloud finalizer compiles consolidated CSV/Parquet in S3 |
| **Monitoring Interface** | HTML viewer (`viewer/index.html`) | Step Functions Console + HTML viewer | Rails Web UI (`:8080`) + HTML viewer | Rails Web UI (`:8080`) | Central Web UI preserved in Option B+ without database locks |
| **Head Node Runtime (per run)** | 0.0 hours | 0.0 hours | **~3.5 hours** (Terminated after run) | **~10.0 hours** (Batch + Ingestion phase) | Ephemeral Head Node terminated immediately after completion |
| **Head Node Compute Cost (3 runs/mo)**| **$0.00 / month** | **$0.00 / month** | **$0.87 – $1.79 / month** | **$2.50 – $5.10 / month** | Based on `t3.large` ($0.0832/h) or `c6i.xlarge` ($0.17/h) |
| **Head Node Ephemeral Storage Cost** | **$0.00 / month** | **$0.00 / month** | **$0.06 / month** (50GB gp3 prorated) | **$0.17 / month** (50GB gp3 prorated) | Discarded when instance is removed |
| **Total Head Node Cost (3 runs/mo)** | **$0.00 / month** | **$0.00 / month** | **~$0.93 – $1.85 / month** | **~$2.67 – $5.27 / month** | Ephemeral provisioning eliminates the $60–$150/mo idle overhead |
| **AWS Batch Compute Cost (3 runs/mo)**| **~$42.50 / month** | **~$42.50 / month** | **~$42.50 / month** | **~$42.50 / month** | 3 x 555.5 vCPU-hours @ Fargate Spot ($0.0255/task-hr) |

---

## 2. Empirical Benchmark Baseline (100 Simulations)

*Benchmark Configuration: SEB 2013 Latin Hypercube Sampling (LHS), 100 datapoints across 10 parallel chunks, AWS Batch `FARGATE_SPOT` (1 vCPU, 8 GB per container task) in `us-east-1` (Account `846898690207`).*

| Metric | Option A: Direct Headless | Option A+: Step Functions Headless | Option B+: Step Functions Head Node | Option B: Traditional Head Node | Delta / Empirical Finding |
| :--- | :--- | :--- | :--- | :--- | :--- |
| **Client Submission / Detach Time** | **13.85s** | **12.50s** (live S3) / **2.51s** | **35.95s** (live S3) / **2.78s** | **35.95s** | **Both Step Functions options free the client laptop immediately (< 3s - 13s)** |
| **Simulation Concurrency** | 10 Fargate Spot tasks | 10 Fargate Spot tasks | 10 Fargate Spot tasks | 10 Fargate Spot tasks | Identical worker compute fleet |
| **Batch Fleet Runtime (100 sims)** | **4 min 54 sec** | **4 min 54 sec** | **4 min 54 sec** | **4 min 54 sec** | ~14–24 sec per annual simulation |
| **State Machine Transition Overhead**| **0.00s** | **~0.80s** | **~0.80s** | N/A (Rails process) | Negligible Step Functions overhead (< 1s across entire workflow) |
| **Simulation Fleet Throughput** | **~1,220 sims / hr** | **~1,220 sims / hr** | **~1,220 sims / hr** | **~1,220 sims / hr** | Scalable to > 30,000 sims/hr at 256 vCPUs |
| **Database Ingestion Time** | **0.00s** (Serverless) | **0.00s** (Serverless) | **0.05s** (S3 summary event) | **22.47s** (MongoDB) | Serial Mongo ingest is ~4.4 dp/s (**extrapolates to 28.5 hrs at 450k runs**) |
| **Local Database Storage Growth** | **0.00 MB** | **0.00 MB** | **< 0.05 MB** (summary link) | **+2.58 MB** data size (+0.62 MB disk) | Traditional Head Node bloats Mongo by +11.6 GB at 450k runs |
| **Final Result Aggregation** | 0.18s (Client-side) | **0.42s** (Cloud container in S3) | **0.42s** (Cloud container in S3) | Database export query | Automated cloud finalizer compiles clean CSV in S3 |
| **Client Laptop Online Need** | Must poll until done | **None (Fire-and-Forget)** | **None (Fire-and-Forget)** | Must stay connected | Both Step Functions options allow laptop to close immediately |
| **Monitoring Dashboard** | HTML viewer (`viewer/index.html`) | Step Functions Console + HTML viewer | Rails Web UI + HTML viewer | Rails Web UI (`:8080`) | Central Web UI preserved in Option B+ without database locks |

---

## 3. Cost Analysis: Ephemeral EC2 Head Node vs. 24/7 Persistent Baseline

When the EC2 Head instance is treated as an **ephemeral control plane** (spun up via Terraform or an auto-scaling schedule only for the duration of a simulation campaign and destroyed afterwards):

### Calculation for 3 Runs / Month (100,000 simulations each):
1. **Option B+ (Step Functions Head Node)**:
   - Each run takes ~3.5 hours total (packaging + batch execution + webhook callback).
   - Total EC2 runtime per month = 3 runs * 3.5 hrs = **10.5 hours / month**.
   - **Compute Cost**:
     - On `t3.large` ($0.0832 / hr): `10.5 * $0.0832` = **$0.87 / month**.
     - On `c6i.xlarge` ($0.1700 / hr): `10.5 * $0.1700` = **$1.79 / month**.
   - **Storage Cost** (50 GB gp3 @ $0.08/GB-mo prorated for 10.5 hours): **~$0.06 / month**.
   - **Total Option B+ Monthly Head Node Cost: ~$0.93 – $1.85 / month**.
2. **Option B (Traditional Head Node)**:
   - Each run must stay online for the 3.2-hour batch run **plus 6.24 hours of serial MongoDB ingestion** = ~10.0 hours per run.
   - Total EC2 runtime per month = 3 runs * 10.0 hrs = **30.0 hours / month**.
   - **Compute Cost**:
     - On `t3.large` ($0.0832 / hr): `30 * $0.0832` = **$2.50 / month**.
     - On `c6i.xlarge` ($0.1700 / hr): `30 * $0.1700` = **$5.10 / month**.
   - **Storage Cost** (50 GB gp3 prorated for 30 hours): **~$0.17 / month**.
   - **Total Option B Monthly Head Node Cost: ~$2.67 – $5.27 / month**.
3. **Persistent 24/7 Baseline (For comparison)**:
   - Running an EC2 Head Node 24/7 (730 hours/month):
     - `t3.large` instance: $60.74 / month.
     - `c6i.xlarge` instance: $124.10 / month.
     - 50 GB gp3 storage: $4.00 / month.
     - Total: **$64.74 – $128.10 / month**.
   - **Key Finding**: Ephemeral provisioning slashes Head Node infrastructure cost by **over 97%** (from ~$65–$128/mo down to **~$1–$5/mo**).

---

## 4. Key Takeaways and Roadmap Guidance for Brian Ball

1. **Option A+ (Step Functions Headless) is the Most Efficient Production Engine**:
   - $0.00 EC2 infrastructure cost.
   - True fire-and-forget: client laptop detaches in ~3 minutes.
   - Cloud finalizer writes clean CSV/Parquet directly to S3.
2. **Option B+ (Step Functions Ephemeral Head Node) is the Best Balance for Web UI Users**:
   - Gives project managers the central Rails Web UI at `:8080`.
   - Ephemeral lifecycle costs only **~$0.93 to $1.85 / month** (for 3 runs/month).
   - Client laptop can be shut down 30 seconds after submitting the analysis.
   - Bypasses the 6.24-hour MongoDB serial ingestion bottleneck via EventBridge completion webhook.
3. **Retain Traditional Option B Only for Adaptive Algorithmic Loops**:
   - Reserved strictly for algorithms like NSGA-II / PSO where new generations are dynamically calculated based on prior evaluation outputs.
