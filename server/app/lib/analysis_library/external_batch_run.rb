# *******************************************************************************
# OpenStudio(R), Copyright (c) Alliance for Sustainable Energy, LLC.
# See also https://openstudio.net/license
# *******************************************************************************

# Run a batch of simulations on an EXTERNAL executor (local mock, Kestrel/SLURM
# array, AWS Batch array) instead of the local simulations queue. Sibling of
# AnalysisLibrary::BatchRun: sampling algorithms (lhs, doe, ...) create the
# 'na' datapoints exactly as before; this class packages them to
# <external_batch_root>/analysis_<id>/package, marks them queued, and then
# incrementally ingests results from .../results until every datapoint is
# terminal. The executor is launched out-of-band (see external_batch/ at the
# repo root); stopping the analysis cancels the still-queued datapoints, which
# ends the wait loop just like batch_run.
class AnalysisLibrary::ExternalBatchRun < AnalysisLibrary::Base
  def initialize(analysis_id, analysis_job_id, options = {})
    defaults = ActiveSupport::HashWithIndifferentAccess.new(
      skip_init: false,
      data_points: [],
      run_data_point_filename: 'run_openstudio.rb',
      problem: {},
      dps_per_chunk: nil,
      sleep_interval: 5,
      auto_dispatch: false,
      step_functions_arn: ENV['AWS_STEP_FUNCTIONS_ARN']
    )
    @options = defaults.deep_merge(options)

    @analysis_id = analysis_id
    @analysis_job_id = analysis_job_id
  end

  def perform
    @analysis = Analysis.find(@analysis_id)

    # get the analysis and report that it is running
    @analysis_job = AnalysisLibrary::Core.initialize_analysis_job(@analysis, @analysis_job_id, @options)

    # reload the object (which is required) because the subdocuments (jobs) may have changed
    @analysis.reload

    data_points = @analysis.data_points.where(status: 'na').to_a
    if data_points.empty?
      logger.warn "No 'na' datapoints found for analysis #{@analysis_id}; nothing to package"
      return
    end

    packager = ExternalBatch::Packager.new(@analysis, data_points,
                                           dps_per_chunk: @options[:dps_per_chunk], logger: logger)
    package_dir = packager.package!
    logger.info "External batch package ready at #{package_dir}; waiting for an external executor to process it"

    dp_ids = data_points.map(&:id)
    data_points.each(&:set_queued_state)

    manifest = JSON.parse(File.read(ExternalBatch.manifest_path(@analysis.id)))
    total_chunks = manifest['chunks'].size

    # Auto-dispatch to AWS Step Functions if configured
    sfn_arn = @options[:step_functions_arn] || ENV['AWS_STEP_FUNCTIONS_ARN']
    if sfn_arn.present? && @options[:auto_dispatch]
      submit_script = File.expand_path('../../../external_batch/aws/submit_batch.rb', __dir__)
      batch_dir = ExternalBatch.batch_dir(@analysis.id)
      bucket = @options[:bucket] || ENV['AWS_BATCH_BUCKET']
      job_queue = @options[:job_queue] || ENV['AWS_BATCH_JOB_QUEUE']
      job_def = @options[:job_definition] || ENV['AWS_BATCH_JOB_DEF']
      region = @options[:region] || ENV['AWS_REGION'] || 'us-east-1'

      if bucket.present? && job_queue.present? && job_def.present?
        cmd = "#{RbConfig.ruby} \"#{submit_script}\" \"#{batch_dir}\" --bucket \"#{bucket}\" --job-queue \"#{job_queue}\" --job-definition \"#{job_def}\" --step-functions \"#{sfn_arn}\" --region \"#{region}\""
        logger.info "Auto-dispatching external batch to Step Functions: #{cmd}"
        system(cmd)
      end
    end
    ingester = ExternalBatch::Ingester.new(@analysis, logger: logger)

    # Watch the results directory until all the datapoints are terminal. Analysis
    # stop cancels queued datapoints (sets them completed), which ends this loop.
    loop do
      ingested = ingester.ingest_new_results
      logger.info "Ingested #{ingested} external batch results for #{@analysis_id}" if ingested > 0

      remaining = @analysis.data_points.where(:_id.in => dp_ids, :status.ne => 'completed').count
      break if remaining == 0

      if ingester.executor_finished?(total_chunks)
        # one final sweep, then mark anything the executor never returned as errored
        ingester.ingest_new_results
        @analysis.data_points.where(:_id.in => dp_ids, :status.ne => 'completed').each do |dp|
          logger.error "External executor finished without returning results for datapoint #{dp.id}; marking errored"
          dp.set_error_flag
          dp.run_start_time ||= Time.now
          dp.run_end_time = Time.now
          dp.status = :completed
          dp.save!
        end
        break
      end

      logger.info "waiting for external batch results for: #{@analysis_id}"
      sleep @options[:sleep_interval]
    end
  rescue StandardError => e
    log_message = "#{__FILE__} failed with #{e.message}, #{e.backtrace.join("\n")}"
    logger.error log_message
    @analysis.status_message = log_message
    @analysis.save!
  ensure
    logger.info 'Finished running external_batch_run method'
    @analysis_job.end_time = Time.now
    @analysis_job.status = 'completed'
    @analysis_job.save!
    @analysis.reload
    @analysis.save!
  end
end
