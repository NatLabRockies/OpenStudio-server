# *******************************************************************************
# OpenStudio(R), Copyright (c) Alliance for Sustainable Energy, LLC.
# See also https://openstudio.net/license
# *******************************************************************************

require 'rails_helper'
require 'tmpdir'
require 'rbconfig'

# AWS Batch control-plane helpers (submit_batch.rb, sync_results.rb) exercised
# against a stub `aws` CLI that emulates S3 as a local folder. The full-pipeline
# spec walks the exact AWS shape: package -> submit (push to "S3") -> array
# tasks run against the S3 copy -> sync results down -> ingest.
RSpec.describe 'ExternalBatch AWS helpers', type: :model do
  include ExternalBatchHelpers

  AWS_DIR = File.expand_path('../external_batch/aws', Rails.root)

  around do |example|
    Dir.mktmpdir do |tmp|
      @batch_root = File.join(tmp, 'batch')
      @fake_s3 = File.join(tmp, 'fake_s3')
      @stub_log = File.join(tmp, 'aws_calls.log')
      FileUtils.mkdir_p [@batch_root, @fake_s3]
      ENV['OS_SERVER_EXTERNAL_BATCH_ROOT'] = @batch_root
      ENV['FAKE_S3_ROOT'] = @fake_s3
      ENV['AWS_STUB_LOG'] = @stub_log
      begin
        example.run
      ensure
        ENV.delete('OS_SERVER_EXTERNAL_BATCH_ROOT')
        ENV.delete('FAKE_S3_ROOT')
        ENV.delete('AWS_STUB_LOG')
      end
    end
  end

  before do
    begin
      Project.destroy_all
      Delayed::Job.destroy_all
    rescue Errno::EACCES
      puts 'Cannot unlink files, will try and continue'
    end
    @aws_cmd = "\"#{RbConfig.ruby}\" \"#{write_stub_aws(@fake_s3)}\""
  end

  def fake_s3_batch_dir(bucket, analysis)
    File.join(@fake_s3, bucket, 'runs', "analysis_#{analysis.id}")
  end

  describe 'submit_batch.rb' do
    it 'pushes the package to S3 and submits an array job sized to the chunk count' do
      analysis, dps = create_fixture_analysis(num_dps: 3)
      ExternalBatch::Packager.new(analysis, dps, dps_per_chunk: 2).package!

      ok = system(RbConfig.ruby, File.join(AWS_DIR, 'submit_batch.rb'),
                  ExternalBatch.batch_dir(analysis.id),
                  '--bucket', 'test-bucket',
                  '--job-queue', 'test-queue',
                  '--job-definition', 'test-jobdef',
                  '--aws-cmd', @aws_cmd)
      expect(ok).to be(true), 'submit_batch.rb exited non-zero'

      # package mirrored into the fake S3 bucket
      expect(File).to exist(File.join(fake_s3_batch_dir('test-bucket', analysis), 'package', 'manifest.json'))
      expect(Dir).to exist(File.join(fake_s3_batch_dir('test-bucket', analysis), 'package', "analysis_#{analysis.id}"))

      # submit-job called with the right shape
      calls = File.readlines(@stub_log).map { |l| JSON.parse(l) }
      submit = calls.detect { |c| c[0] == 'batch' && c[1] == 'submit-job' }
      expect(submit).not_to be_nil
      expect(submit).to include('--job-queue', 'test-queue', '--job-definition', 'test-jobdef')
      expect(submit.join(' ')).to include('size=2') # 3 dps at 2/chunk = 2 array tasks
      expect(submit.join(' ')).to include("BATCH_S3_URI,value=s3://test-bucket/runs/analysis_#{analysis.id}")
    end

    it 'submits a plain job with CHUNK_INDEX for a single chunk (Batch arrays need size >= 2)' do
      analysis, dps = create_fixture_analysis(num_dps: 2)
      ExternalBatch::Packager.new(analysis, dps, dps_per_chunk: 50).package! # 1 chunk

      ok = system(RbConfig.ruby, File.join(AWS_DIR, 'submit_batch.rb'),
                  ExternalBatch.batch_dir(analysis.id),
                  '--bucket', 'test-bucket', '--job-queue', 'q', '--job-definition', 'jd',
                  '--aws-cmd', @aws_cmd)
      expect(ok).to be true

      submit = File.readlines(@stub_log).map { |l| JSON.parse(l) }.detect { |c| c[1] == 'submit-job' }
      expect(submit.join(' ')).not_to include('--array-properties')
      expect(submit.join(' ')).to include('CHUNK_INDEX,value=0')
    end
  end

  describe 'Step Functions state machine ASL definition' do
    let(:asl_path) { File.join(AWS_DIR, 'orchestration', 'state_machine.asl.json') }

    it 'exists and parses as valid JSON' do
      expect(File).to exist(asl_path)
      parsed = JSON.parse(File.read(asl_path))
      expect(parsed['StartAt']).to eq('ValidatePackage')
      expect(parsed['States']).to have_key('SubmitBatchArrayJob')
      expect(parsed['States']).to have_key('SubmitBatchSingleJob')
      expect(parsed['States']).to have_key('EvaluateFailureThreshold')
      expect(parsed['States']).to have_key('RunFinalizer')
      expect(parsed['States']).to have_key('CheckNotification')
    end

    it 'configures sync batch task integration with error retries' do
      parsed = JSON.parse(File.read(asl_path))
      array_task = parsed['States']['SubmitBatchArrayJob']
      expect(array_task['Type']).to eq('Task')
      expect(array_task['Resource']).to eq('arn:aws:states:::batch:submitJob.sync')
      expect(array_task['Parameters']['ArrayProperties']['Size.$']).to eq('$.NumChunks')
      expect(array_task['Retry']).not_to be_empty
      expect(array_task['Retry'].first['ErrorEquals']).to include('Batch.ServerException')
    end

    it 'configures finalizer task with BATCH_TASK_MODE=finalize' do
      parsed = JSON.parse(File.read(asl_path))
      finalizer = parsed['States']['RunFinalizer']
      expect(finalizer['Type']).to eq('Task')
      expect(finalizer['Resource']).to eq('arn:aws:states:::batch:submitJob.sync')
      env = finalizer['Parameters']['ContainerOverrides']['Environment']
      mode_env = env.detect { |e| e['Name'] == 'BATCH_TASK_MODE' }
      expect(mode_env['Value']).to eq('finalize')
    end
  end

  describe 'submit_batch.rb with Step Functions' do
    it 'pushes package to S3 and triggers state machine execution in fire-and-forget mode' do
      analysis, dps = create_fixture_analysis(num_dps: 3)
      ExternalBatch::Packager.new(analysis, dps, dps_per_chunk: 2).package!
      sfn_arn = 'arn:aws:states:us-east-1:123456789012:stateMachine:test-orchestrator'

      ok = system(RbConfig.ruby, File.join(AWS_DIR, 'submit_batch.rb'),
                  ExternalBatch.batch_dir(analysis.id),
                  '--bucket', 'test-bucket',
                  '--job-queue', 'test-queue',
                  '--job-definition', 'test-jobdef',
                  '--step-functions', sfn_arn,
                  '--aws-cmd', @aws_cmd)
      expect(ok).to be true

      # package mirrored into the fake S3 bucket
      expect(File).to exist(File.join(fake_s3_batch_dir('test-bucket', analysis), 'package', 'manifest.json'))

      # stepfunctions start-execution called
      calls = File.readlines(@stub_log).map { |l| JSON.parse(l) }
      sfn_call = calls.detect { |c| c[0] == 'stepfunctions' && c[1] == 'start-execution' }
      expect(sfn_call).not_to be_nil
      expect(sfn_call).to include('--state-machine-arn', sfn_arn)

      input_idx = sfn_call.index('--input')
      expect(input_idx).not_to be_nil
      payload = JSON.parse(sfn_call[input_idx + 1])
      expect(payload['AnalysisId']).to eq(analysis.id)
      expect(payload['JobQueue']).to eq('test-queue')
      expect(payload['JobDefinition']).to eq('test-jobdef')
      expect(payload['NumChunks']).to eq(2)
      expect(payload['BatchS3Uri']).to eq("s3://test-bucket/runs/analysis_#{analysis.id}")
      expect(payload['AllowPartialFailure']).to be false
    end

    it 'passes SNS topic and wait flag when requested' do
      analysis, dps = create_fixture_analysis(num_dps: 1)
      ExternalBatch::Packager.new(analysis, dps, dps_per_chunk: 10).package!
      sfn_arn = 'arn:aws:states:us-east-1:123456789012:stateMachine:test-orchestrator'
      sns_arn = 'arn:aws:sns:us-east-1:123456789012:test-topic'

      ok = system(RbConfig.ruby, File.join(AWS_DIR, 'submit_batch.rb'),
                  ExternalBatch.batch_dir(analysis.id),
                  '--bucket', 'test-bucket',
                  '--job-queue', 'q',
                  '--job-definition', 'jd',
                  '--step-functions', sfn_arn,
                  '--sns-topic', sns_arn,
                  '--wait',
                  '--allow-partial-failure',
                  '--aws-cmd', @aws_cmd)
      expect(ok).to be true

      calls = File.readlines(@stub_log).map { |l| JSON.parse(l) }
      sfn_call = calls.detect { |c| c[0] == 'stepfunctions' && c[1] == 'start-execution' }
      expect(sfn_call).not_to be_nil
      payload = JSON.parse(sfn_call[sfn_call.index('--input') + 1])
      expect(payload['SnsTopicArn']).to eq(sns_arn)
      expect(payload['AllowPartialFailure']).to be true

      describe_call = calls.detect { |c| c[0] == 'stepfunctions' && c[1] == 'describe-execution' }
      expect(describe_call).not_to be_nil
    end
  end

  describe 'cloud-side finalizer aggregation' do
    it 'runs automated CSV aggregation and produces aggregated_measure_attributes.csv in S3 results' do
      analysis, dps = create_fixture_analysis(num_dps: 2)
      ExternalBatch::Packager.new(analysis, dps, dps_per_chunk: 1).package!
      s3_dir = fake_s3_batch_dir('test-bucket', analysis)

      # Populate sample datapoint results in S3 results/
      dps.each_with_index do |dp, idx|
        dp_results = File.join(s3_dir, 'results', dp.id)
        FileUtils.mkdir_p(dp_results)
        File.write(File.join(dp_results, 'status.json'),
                   JSON.generate('status' => 'completed',
                                 'started_at' => Time.now.to_s,
                                 'completed_at' => (Time.now + 15).to_s))
        File.write(File.join(dp_results, 'measure_attributes.json'),
                   JSON.generate('stub_measure' => { 'ran' => true, 'sample_val' => idx }))
      end

      # Execute aggregation as run by finalizer container
      finalizer_csv = File.join(s3_dir, 'results', 'aggregated_measure_attributes.csv')
      aggregator_script = File.expand_path('../external_batch/demo/aggregate_csv.rb', Rails.root)
      ok = system(RbConfig.ruby, aggregator_script, File.join(s3_dir, 'results'), finalizer_csv)
      expect(ok).to be true
      expect(File).to exist(finalizer_csv)

      rows = CSV.read(finalizer_csv, headers: true)
      expect(rows.size).to eq 2
      expect(rows.headers).to include('datapoint_id', 'status', 'duration_seconds', 'stub_measure.sample_val')
      expect(rows.map { |r| r['stub_measure.sample_val'] }.sort).to eq %w[0 1]
    end
  end

  describe 'full AWS-shaped pipeline' do
    it 'package -> submit -> array tasks against S3 copy -> sync_results -> ingest' do
      analysis, dps = create_fixture_analysis(num_dps: 2)
      ExternalBatch::Packager.new(analysis, dps, dps_per_chunk: 1).package!
      dps.each(&:set_queued_state)
      batch_dir = ExternalBatch.batch_dir(analysis.id)
      s3_uri = "s3://test-bucket/runs/analysis_#{analysis.id}"

      # 1. control plane: push package + "submit" the array job
      ok = system(RbConfig.ruby, File.join(AWS_DIR, 'submit_batch.rb'), batch_dir,
                  '--bucket', 'test-bucket', '--job-queue', 'q', '--job-definition', 'jd',
                  '--aws-cmd', @aws_cmd)
      expect(ok).to be true

      # 2. the "array tasks": the fake-S3 batch dir has the same shape as a local
      #    batch dir, so drive it with the local executor + stub OpenStudio CLI
      #    (this is what task_wrapper.sh does inside each container)
      stub_cli = write_stub_openstudio(@fake_s3)
      ok = system(RbConfig.ruby, File.expand_path('../external_batch/local_executor.rb', Rails.root),
                  fake_s3_batch_dir('test-bucket', analysis),
                  '--openstudio', "\"#{RbConfig.ruby}\" \"#{stub_cli}\"",
                  '--parallel', '2')
      expect(ok).to be(true), 'array-task simulation failed'

      # 3. transport: mirror the S3 results down to the server's batch dir
      ok = system(RbConfig.ruby, File.join(AWS_DIR, 'sync_results.rb'), batch_dir,
                  '--s3-uri', s3_uri, '--aws-cmd', @aws_cmd, '--interval', '0')
      expect(ok).to be(true), 'sync_results.rb exited non-zero'

      # 4. ingest: the server-side loop sees the results as local files
      ingester = ExternalBatch::Ingester.new(analysis)
      expect(ingester.executor_finished?(2)).to be true
      expect(ingester.ingest_new_results).to eq 2

      dps.each do |dp|
        dp.reload
        expect(dp.status).to eq 'completed'
        expect(dp.status_message).to eq 'completed normal'
        expect(dp.results['stub_measure']['ran']).to eq true
      end

      # 5. headless CSV aggregation: verify aggregate_csv.rb produces expected CSV from results
      aggregator_script = File.expand_path('../external_batch/demo/aggregate_csv.rb', Rails.root)
      csv_out = File.join(batch_dir, 'results', 'aggregated_measure_attributes.csv')
      ok = system(RbConfig.ruby, aggregator_script, File.join(batch_dir, 'results'), csv_out)
      expect(ok).to be true
      expect(File).to exist(csv_out)
      rows = CSV.read(csv_out, headers: true)
      expect(rows.size).to eq 2
      expect(rows.headers).to include('datapoint_id', 'status', 'duration_seconds', 'stub_measure.ran')
      expect(%w(Success completed)).to include(rows[0]['status'])
      expect(rows[0]['stub_measure.ran']).to eq 'true'
    end
  end
end
