# *******************************************************************************
# OpenStudio(R), Copyright (c) Alliance for Sustainable Energy, LLC.
# See also https://openstudio.net/license
# *******************************************************************************

# Shared helpers for the external batch specs.
module ExternalBatchHelpers
  # Seeds Mongo the same way the API upload path does (analyses_controller#create + #upload)
  def create_fixture_analysis(num_dps: 3)
    project = Project.create(name: 'external batch spec')
    hash = JSON.parse(File.read(Rails.root.join('spec', 'files', 'batch_datapoints', 'example_csv.json')))
    analysis = project.analyses.new(hash['analysis'])
    analysis.save!
    analysis.pull_out_os_variables
    analysis.seed_zip = File.new(Rails.root.join('spec', 'files', 'batch_datapoints', 'example_csv.zip'))
    analysis.save!

    variables = Variable.where(analysis_id: analysis.id, perturbable: true).order_by(:name.asc).to_a
    raise 'fixture produced no perturbable variables' if variables.empty?

    data_points = (1..num_dps).map do |i|
      svv = variables.map { |v| [v.id.to_s, 1 + (i % 2)] }.to_h
      analysis.data_points.create!(name: "external batch dp #{i}", set_variable_values: svv)
    end
    [analysis, data_points]
  end

  # Stub of `openstudio run --workflow <osw>`: writes the artifact set the
  # runner collects, without running EnergyPlus.
  def write_stub_openstudio(dir)
    stub_path = File.join(dir, 'fake_openstudio.rb')
    File.write(stub_path, <<~RUBY)
      require 'json'
      require 'fileutils'

      i = ARGV.index('--workflow')
      abort 'no --workflow given' unless i
      osw = ARGV[i + 1]
      dp_dir = File.dirname(osw)
      run_dir = File.join(dp_dir, 'run')
      FileUtils.mkdir_p run_dir
      FileUtils.mkdir_p File.join(dp_dir, 'reports')

      File.write(File.join(dp_dir, 'out.osw'), JSON.generate(completed_status: 'Success', steps: []))
      File.write(File.join(run_dir, 'run.log'), "stub run\\n")
      File.write(File.join(run_dir, 'measure_attributes.json'), JSON.generate(stub_measure: { ran: true }))
      File.write(File.join(run_dir, 'objectives.json'), '{}')
      File.write(File.join(run_dir, 'data_point.zip'), 'PK stub')
      File.write(File.join(run_dir, 'in.osm'), 'OS:Version,;')
      File.write(File.join(dp_dir, 'reports', 'stub_report.html'), '<html></html>')
    RUBY
    stub_path
  end

  # Stub of the AWS CLI: `s3 sync` copies between local dirs (s3://bucket/key
  # maps to FAKE_S3_ROOT/bucket/key) and `batch submit-job` prints a fake job
  # id. Every invocation is appended to AWS_STUB_LOG as a JSON argv line.
  def write_stub_aws(dir)
    stub_path = File.join(dir, 'fake_aws.rb')
    File.write(stub_path, <<~RUBY)
      require 'json'
      require 'fileutils'

      fake_root = ENV['FAKE_S3_ROOT'] || abort('FAKE_S3_ROOT not set')
      log_path = ENV['AWS_STUB_LOG']
      File.open(log_path, 'a') { |f| f.puts JSON.generate(ARGV) } if log_path

      def resolve(path, fake_root)
        path.start_with?('s3://') ? File.join(fake_root, path.sub('s3://', '')) : path
      end

      argv = ARGV.dup
      service = argv.shift
      case service
      when 's3'
        cmd = argv.shift
        case cmd
        when 'sync'
          delete = !argv.delete('--delete').nil?
          argv.delete('--only-show-errors')
          if (i = argv.index('--region'))
            argv.slice!(i, 2)
          end
          src = resolve(argv[0], fake_root)
          dst = resolve(argv[1], fake_root)
          abort "sync source \#{src} does not exist" unless Dir.exist?(src)
          FileUtils.rm_rf(dst) if delete
          FileUtils.mkdir_p(dst)
          FileUtils.cp_r(File.join(src, '.'), dst)
        when 'cp'
          argv.delete('--only-show-errors')
          if (i = argv.index('--region'))
            argv.slice!(i, 2)
          end
          src = resolve(argv[0], fake_root)
          dst = resolve(argv[1], fake_root)
          FileUtils.mkdir_p(File.dirname(dst))
          FileUtils.cp(src, dst)
        else
          abort "unsupported s3 command \#{cmd}"
        end
      when 'batch'
        puts 'fake-job-123'
      when 'stepfunctions'
        cmd = argv.shift
        case cmd
        when 'start-execution'
          puts JSON.generate({
            'executionArn' => 'arn:aws:states:us-east-1:123456789012:execution:osaf-batch-orchestrator:fake-exec-1',
            'startDate' => Time.now.to_s
          })
        when 'describe-execution'
          puts JSON.generate({
            'executionArn' => 'arn:aws:states:us-east-1:123456789012:execution:osaf-batch-orchestrator:fake-exec-1',
            'status' => 'SUCCEEDED',
            'startDate' => Time.now.to_s,
            'stopDate' => (Time.now + 10).to_s
          })
        else
          abort "unsupported stepfunctions command \#{cmd}"
        end
      else
        abort "unsupported service \#{service}"
      end
    RUBY
    stub_path
  end
end
