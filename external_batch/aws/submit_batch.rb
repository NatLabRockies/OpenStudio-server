#!/usr/bin/env ruby

# *******************************************************************************
# OpenStudio(R), Copyright (c) Alliance for Sustainable Energy, LLC.
# See also https://openstudio.net/license
# *******************************************************************************

# Control-plane helper: pushes a packaged batch dir to S3 and submits one AWS
# Batch array job (one array task per chunk). Plain Ruby driving the AWS CLI —
# credentials come from the standard AWS CLI chain (env vars, ~/.aws, SSO).
# Data never flows through this script; only the manifest is read locally.
#
# Usage:
#   ruby submit_batch.rb BATCH_DIR --bucket my-bucket --job-queue Q --job-definition D
#   ruby submit_batch.rb BATCH_DIR --s3-uri s3://my-bucket/runs/analysis_<id> ...
#
# After submitting, run sync_results.rb (printed at the end) so the server's
# ingest loop sees the results as they land.

require 'json'
require 'optparse'

options = {
  bucket: nil,
  s3_uri: nil,
  job_queue: nil,
  job_definition: nil,
  job_name: nil,
  region: nil,
  aws_cmd: 'aws',
  dry_run: false,
  step_functions: nil,
  wait: false,
  allow_partial_failure: false,
  sns_topic: nil
}
opt_parser = OptionParser.new do |o|
  o.banner = 'Usage: ruby submit_batch.rb BATCH_DIR [options]'
  o.on('--bucket NAME', 'S3 bucket; batch dir goes to s3://NAME/runs/analysis_<id>') { |v| options[:bucket] = v }
  o.on('--s3-uri URI', 'Explicit s3:// URI for the batch dir (overrides --bucket)') { |v| options[:s3_uri] = v.chomp('/') }
  o.on('--job-queue NAME', 'AWS Batch job queue') { |v| options[:job_queue] = v }
  o.on('--job-definition NAME', 'AWS Batch job definition (runner image)') { |v| options[:job_definition] = v }
  o.on('--job-name NAME', 'Job name (default osaf-batch-analysis-<id>)') { |v| options[:job_name] = v }
  o.on('--region REGION', 'AWS region (default: AWS CLI default chain)') { |v| options[:region] = v }
  o.on('--aws-cmd CMD', 'AWS CLI command (default `aws`; stub for tests)') { |v| options[:aws_cmd] = v }
  o.on('--dry-run', 'Print the commands without executing them') { options[:dry_run] = true }
  o.on('--step-functions ARN', 'State machine ARN; orchestrates batch job and cloud-side finalization') { |v| options[:step_functions] = v }
  o.on('--wait', 'Wait for Step Functions execution to complete (default: fire-and-forget)') { options[:wait] = true }
  o.on('--allow-partial-failure', 'Allow finalizer to run even if some tasks fail') { options[:allow_partial_failure] = true }
  o.on('--sns-topic ARN', 'SNS topic for completion notification') { |v| options[:sns_topic] = v }
end
opt_parser.parse!

batch_dir = ARGV.shift
abort opt_parser.banner if batch_dir.nil?
batch_dir = File.expand_path(batch_dir)

manifest_path = File.join(batch_dir, 'package', 'manifest.json')
abort "No manifest.json at #{manifest_path} — package the analysis first" unless File.exist?(manifest_path)
manifest = JSON.parse(File.read(manifest_path))
analysis_id = manifest['analysis_id']
num_chunks = manifest['chunks'].size

abort '--job-queue and --job-definition are required' if options[:job_queue].nil? || options[:job_definition].nil?
s3_uri = options[:s3_uri]
s3_uri ||= "s3://#{options[:bucket]}/runs/analysis_#{analysis_id}" if options[:bucket]
abort 'Provide --bucket or --s3-uri' if s3_uri.nil?

region_arg = options[:region] ? " --region #{options[:region]}" : ''
job_name = options[:job_name] || "osaf-batch-analysis-#{analysis_id}"

def run!(cmd, dry_run)
  puts "+ #{cmd}"
  return if dry_run

  system(cmd) || abort("Command failed: #{cmd}")
end

# 1. push the package (--delete keeps a re-submit consistent with a re-package)
run!("#{options[:aws_cmd]} s3 sync --only-show-errors --delete \"#{File.join(batch_dir, 'package')}\" \"#{s3_uri}/package\"#{region_arg}",
     options[:dry_run])

# 2. dispatch via Step Functions or direct AWS Batch
if options[:step_functions]
  input_payload = {
    AnalysisId: analysis_id,
    JobName: job_name,
    JobQueue: options[:job_queue],
    JobDefinition: options[:job_definition],
    BatchS3Uri: s3_uri,
    NumChunks: num_chunks,
    AllowPartialFailure: options[:allow_partial_failure] || false
  }
  input_payload[:SnsTopicArn] = options[:sns_topic] if options[:sns_topic]

  exec_name = "#{job_name}-#{Time.now.to_i}"
  json_input = JSON.generate(input_payload).gsub('"', '\\"')

  sfn_cmd = "#{options[:aws_cmd]} stepfunctions start-execution" \
            " --state-machine-arn #{options[:step_functions]}" \
            " --name #{exec_name}" \
            " --input \"#{json_input}\"" \
            "#{region_arg}" \
            ' --output json'
  puts "+ #{sfn_cmd}"

  unless options[:dry_run]
    raw_res = `#{sfn_cmd}`
    abort 'stepfunctions start-execution failed' unless $?.success? && !raw_res.empty?
    parsed = JSON.parse(raw_res) rescue {}
    exec_arn = parsed['executionArn'] || 'unknown-arn'
    puts "Started Step Functions execution for analysis #{analysis_id}:"
    puts "  Execution ARN: #{exec_arn}"
    puts "  Start Date:    #{parsed['startDate']}"

    if options[:wait]
      puts 'Waiting for Step Functions execution to finish...'
      loop do
        sleep 5
        status_cmd = "#{options[:aws_cmd]} stepfunctions describe-execution --execution-arn #{exec_arn}#{region_arg} --output json"
        status_json = `#{status_cmd}`
        cur_status = (JSON.parse(status_json)['status'] rescue 'RUNNING')
        puts "  Status: #{cur_status} (#{Time.now.strftime('%H:%M:%S')})"
        if %w[SUCCEEDED FAILED TIMED_OUT ABORTED].include?(cur_status)
          abort "Execution finished with status: #{cur_status}" unless cur_status == 'SUCCEEDED'
          puts 'Execution succeeded!'
          break
        end
      end
    else
      puts "\nFire-and-forget submission active. Workstation can detach immediately."
      puts 'Check execution status:'
      puts "  #{options[:aws_cmd]} stepfunctions describe-execution --execution-arn #{exec_arn}#{region_arg}"
    end
  end
else
  # Direct AWS Batch array job (Batch requires array size >= 2; single chunk = plain job)
  env_overrides = "{name=BATCH_S3_URI,value=#{s3_uri}}"
  if num_chunks >= 2
    array_arg = " --array-properties size=#{num_chunks}"
  else
    array_arg = ''
    env_overrides += ',{name=CHUNK_INDEX,value=0}'
  end

  submit_cmd = "#{options[:aws_cmd]} batch submit-job" \
               " --job-name #{job_name}" \
               " --job-queue #{options[:job_queue]}" \
               " --job-definition #{options[:job_definition]}" \
               "#{array_arg}" \
               " --container-overrides \"environment=[#{env_overrides}]\"" \
               "#{region_arg}" \
               ' --output text --query jobId'
  puts "+ #{submit_cmd}"
  unless options[:dry_run]
    job_id = `#{submit_cmd}`.strip
    abort 'submit-job failed' unless $?.success? && !job_id.empty?
    puts "Submitted #{num_chunks} chunk(s) for analysis #{analysis_id}: jobId=#{job_id}"
  end
end

puts
puts 'Next, mirror the results down for the server ingest loop:'
puts "  ruby #{File.expand_path(File.join(__dir__, 'sync_results.rb'))} \"#{batch_dir}\" --s3-uri #{s3_uri}#{options[:region] ? " --region #{options[:region]}" : ''}"
