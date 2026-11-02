#!/bin/bash
# Entrypoint for one AWS Batch array task = one chunk.
#
# Required env (set via the job definition / submit-time container overrides):
#   BATCH_S3_URI   s3://<bucket>/runs/analysis_<id>  (the batch dir in S3)
# Optional env:
#   CHUNK_INDEX    chunk to run; defaults to AWS_BATCH_JOB_ARRAY_INDEX (array job)
#
# No AWS keys anywhere in here: the container gets its S3 permissions from the
# IAM task role attached to the job definition (picked up automatically by the
# AWS CLI from the ECS credential endpoint).
set -euo pipefail

: "${BATCH_S3_URI:?BATCH_S3_URI env var is required (s3://bucket/prefix of the batch dir)}"

MODE="${BATCH_TASK_MODE:-simulate}"

if [ "$MODE" = "finalize" ]; then
  echo "[task_wrapper] Running automated finalizer / aggregation for ${BATCH_S3_URI}"
  WORK="${TMPDIR:-/tmp}/osaf_batch_finalize"
  mkdir -p "${WORK}/results"
  echo "[task_wrapper] Syncing results from ${BATCH_S3_URI}/results"
  aws s3 sync --only-show-errors "${BATCH_S3_URI}/results" "${WORK}/results"
  
  if [ -f "/usr/local/openstudio-batch/aggregate_csv.rb" ]; then
    ruby /usr/local/openstudio-batch/aggregate_csv.rb "${WORK}/results" "${WORK}/results/aggregated_measure_attributes.csv"
  else
    ruby -e '
      require "json"; require "csv"; require "set"; require "time"
      results_dir = ARGV[0]
      output_csv = ARGV[1]
      rows = []; all_headers = Set.new(["datapoint_id", "status", "duration_seconds"])
      Dir.glob(File.join(results_dir, "*")).each do |dp_dir|
        next unless File.directory?(dp_dir)
        dp_id = File.basename(dp_dir)
        status_file = File.join(dp_dir, "status.json")
        measure_file = File.join(dp_dir, "measure_attributes.json")
        next unless File.exist?(status_file)
        status_data = JSON.parse(File.read(status_file)) rescue {}
        measure_data = File.exist?(measure_file) ? (JSON.parse(File.read(measure_file)) rescue {}) : {}
        duration = 0
        if status_data["started_at"] && status_data["completed_at"]
          duration = (Time.parse(status_data["completed_at"]) - Time.parse(status_data["started_at"])).round(2) rescue 0
        end
        row = {"datapoint_id" => dp_id, "status" => status_data["status"] || status_data["completed_status"] || "completed", "duration_seconds" => duration}
        measure_data.each do |measure_name, attrs|
          if attrs.is_a?(Hash)
            attrs.each { |k, v| col = "#{measure_name}.#{k}"; all_headers << col; row[col] = v }
          else
            col = measure_name.to_s; all_headers << col; row[col] = attrs
          end
        end
        rows << row
      end
      headers = all_headers.to_a.sort
      CSV.open(output_csv, "w", write_headers: true, headers: headers) do |csv|
        rows.sort_by { |r| r["datapoint_id"] }.each { |r| csv << headers.map { |h| r[h] } }
      end
      puts "Aggregated #{rows.size} datapoints into #{output_csv}"
    ' "${WORK}/results" "${WORK}/results/aggregated_measure_attributes.csv"
  fi
  
  echo "[task_wrapper] Uploading aggregated_measure_attributes.csv to ${BATCH_S3_URI}/results/"
  aws s3 cp --only-show-errors "${WORK}/results/aggregated_measure_attributes.csv" "${BATCH_S3_URI}/results/aggregated_measure_attributes.csv"
  echo "[task_wrapper] Finalization complete."
  exit 0
fi

CHUNK="${CHUNK_INDEX:-${AWS_BATCH_JOB_ARRAY_INDEX:-0}}"

WORK="${TMPDIR:-/tmp}/osaf_batch_chunk_${CHUNK}"
mkdir -p "${WORK}/package" "${WORK}/results"

# Push whatever results exist even if the runner dies mid-chunk; the ingester
# only reads dp folders that contain status.json, so partial pushes are safe.
push_results() {
  aws s3 sync --only-show-errors "${WORK}/results" "${BATCH_S3_URI}/results" || true
}
trap push_results EXIT

echo "[task_wrapper] chunk ${CHUNK}: syncing package from ${BATCH_S3_URI}/package"
aws s3 sync --only-show-errors "${BATCH_S3_URI}/package" "${WORK}/package"

echo "[task_wrapper] chunk ${CHUNK}: running"
ruby /usr/local/openstudio-batch/run_chunk.rb \
  --package "${WORK}/package" \
  --results "${WORK}/results" \
  --chunk "${CHUNK}" \
  --openstudio openstudio

echo "[task_wrapper] chunk ${CHUNK}: done"
