# AWS Batch executor

Runs external batch packages on AWS Batch array jobs. One array task = one
chunk from `manifest.json`; the container pulls the package from S3, runs its
chunk with the OpenStudio CLI, and pushes the finished result folders back to
S3.

Two operational models are supported:
- **Option A: Headless External Batch (Serverless CLI & Step Functions)**: Direct S3 + `submit_batch.rb` without MongoDB or Rails. Supports direct array submission or fire-and-forget orchestration via AWS Step Functions (`--step-functions`), zero idle overhead, instant client detach (< 13s), and viewable via the lightweight HTML dashboard (`viewer/index.html`).
- **Option B: Cloud Head Node External Batch (Full Server)**: OpenStudio Server (mongod + Rails API/UI) hosted on an EC2 instance (`t3.large`/`c6i.xlarge`) provisioned via Terraform, coordinating AWS Batch workers.

See [HEAD_VS_HEADLESS.md](HEAD_VS_HEADLESS.md) for a comprehensive architectural comparison, performance benchmarks, and deployment guidance.

## What the user must provide

| what | where it goes | how often |
|---|---|---|
| AWS account + credentials (access key/secret via `aws configure`, or SSO/`AWS_PROFILE`) | your workstation / the server host only — standard AWS CLI credential chain; nothing custom | once |
| Region | `terraform apply -var region=...` and `--region` on the helpers (or your AWS CLI default) | once |
| Globally-unique S3 bucket name | `terraform apply -var bucket_name=...` | once |
| Docker (to build/push the runner image) | your workstation | once per OpenStudio version |
| Job queue + job definition names | printed by `terraform output`; passed to `submit_batch.rb` | per run |

**Containers get NO credentials.** The job definition attaches an IAM *task
role* scoped to `s3://<bucket>/runs/*`; the AWS CLI inside the container picks
it up automatically. Your access keys never leave your machine.

NREL/corporate network note: if `aws` calls fail with SSL errors behind the
proxy, add `ca_bundle = /path/to/corp-cert.pem` under `[default]` in
`~/.aws/config`.

## One-time setup

```bash
cd external_batch/aws/infra
terraform init
terraform apply -var region=us-west-2 -var bucket_name=<unique-bucket-name>
# outputs: bucket_name, ecr_repository_url, job_queue, job_definition

# build + push the runner image (from external_batch/):
cd ..
aws ecr get-login-password | docker login --username AWS --password-stdin <ecr_repository_url%/*>
docker build -f aws/Dockerfile --build-arg OPENSTUDIO_VERSION=3.11.0 -t <ecr_repository_url>:3.11.0 ..
docker push <ecr_repository_url>:3.11.0
```

## Per run

```bash
# 1-2. start the local server and submit the analysis as usual:
ruby bin/openstudio_meta start_local --worker-number 1 ./my_project
ruby bin/openstudio_meta run_analysis -a lhs --batch-run-method external_batch_run \
    my_analysis.json http://localhost:8080
# server packages to <project>/temp_data/external_batch/analysis_<id>

# 3. push the package + submit the array job:
# Option A (Direct Batch):
ruby external_batch/aws/submit_batch.rb <project>/temp_data/external_batch/analysis_<id> \
    --bucket <bucket> --job-queue osaf-batch-queue --job-definition osaf-batch-runner

# Option A+ (Fire-and-Forget via Step Functions with Automated Post-Processing):
ruby external_batch/aws/submit_batch.rb <project>/temp_data/external_batch/analysis_<id> \
    --bucket <bucket> --job-queue osaf-batch-queue --job-definition osaf-batch-runner \
    --step-functions arn:aws:states:<region>:<account>:stateMachine:osaf-batch-orchestrator

# 4. For direct batch, mirror results down until all chunks are done (server ingests as they land):
ruby external_batch/aws/sync_results.rb <project>/temp_data/external_batch/analysis_<id> \
    --s3-uri s3://<bucket>/runs/analysis_<id>
# Note: In Step Functions mode, cloud-side finalization runs automatically in S3!
```

Watch task states with `aws batch list-jobs --job-queue osaf-batch-queue
--array-job-id <jobId>` or the AWS console; watch analysis progress in the
normal server UI/status endpoints.

## Lightweight Results Viewer

For headless runs or quick local inspection, open `external_batch/aws/viewer/index.html` in any modern web browser. It is a single-file, zero-dependency dashboard that provides:
- Real-time simulation progress bars (Succeeded / Failed / Queued).
- Datapoint status table with search and filtering.
- One-click modal diagnostics displaying `run.log`, `eplusout.err`, and `status.json`.

Simply click **Select Results Directory** and point it to the local or synced results directory (`<batch_dir>/results` or `s3://<bucket>/runs/analysis_<id>/results`).

## Provisioning the Cloud Head Node (Option B)

To provision an optional EC2 head node alongside the AWS Batch compute environment:

```bash
cd external_batch/aws/infra
terraform apply -var-file=nrel-846898690207.tfvars -var enable_head_node=true
```

The output will include `head_node_ui_url` (port 8080) for web browser access.

## Sizing / cost behavior

- Parallelism = number of chunks (array size). Each task is 1 vCPU + ~8 GB and
  runs its datapoints one at a time, so `dps_per_chunk` trades task count
  against task walltime (target 1–4 h).
- The compute environment scales from 0 to `max_vcpus` (default 256 = 256
  concurrent sims) and back to 0 when idle — you pay only while tasks run.
- On-demand instances by default (btap_batch's model); chunks are idempotent,
  so a spot variant is possible later behind a flag.
- `results_expire_days` (default 30) auto-cleans `runs/` in S3.

## Failure handling

- A task that dies is retried once by Batch (`retry_strategy`); re-running a
  chunk is safe because results land atomically (status.json written last) and
  the ingester skips completed datapoints.
- A chunk that never returns results: when all done-markers arrive the server
  marks the missing datapoints errored and completes the analysis. If a task
  died without a done marker, re-submit just that chunk
  (`submit_batch.rb --dry-run` shows the command; add `CHUNK_INDEX` override)
  or re-run it locally with `run_chunk.rb --chunk N`.
