#!/usr/bin/env ruby
# Aggregates measure_attributes.json from results/ into a clean CSV

require 'json'
require 'csv'
require 'set'
require 'time'
require 'fileutils'

results_dir = ARGV[0] || abort("Usage: ruby aggregate_csv.rb <results_dir> [output.csv]")
output_csv = ARGV[1] || File.join(results_dir, "aggregated_measure_attributes.csv")

puts "Scanning #{results_dir} for completed datapoint results..."

rows = []
all_headers = Set.new(['datapoint_id', 'status', 'duration_seconds'])

Dir.glob(File.join(results_dir, "*")).each do |dp_dir|
  next unless File.directory?(dp_dir)
  dp_id = File.basename(dp_dir)
  status_file = File.join(dp_dir, "status.json")
  measure_file = File.join(dp_dir, "measure_attributes.json")
  
  next unless File.exist?(status_file)
  status_data = JSON.parse(File.read(status_file)) rescue {}
  measure_data = File.exist?(measure_file) ? (JSON.parse(File.read(measure_file)) rescue {}) : {}

  duration = 0
  if status_data['started_at'] && status_data['completed_at']
    duration = (Time.parse(status_data['completed_at']) - Time.parse(status_data['started_at'])).round(2) rescue 0
  end

  row = {
    'datapoint_id' => dp_id,
    'status' => status_data['status'] || status_data['completed_status'] || 'completed',
    'duration_seconds' => duration
  }

  # Flatten measure attributes
  measure_data.each do |measure_name, attrs|
    if attrs.is_a?(Hash)
      attrs.each do |attr_key, attr_val|
        col_name = "#{measure_name}.#{attr_key}"
        all_headers << col_name
        row[col_name] = attr_val
      end
    else
      col_name = measure_name.to_s
      all_headers << col_name
      row[col_name] = attrs
    end
  end

  rows << row
end

headers = all_headers.to_a.sort
CSV.open(output_csv, 'w', write_headers: true, headers: headers) do |csv|
  rows.sort_by { |r| r['datapoint_id'] }.each do |r|
    csv << headers.map { |h| r[h] }
  end
end

puts "Aggregated #{rows.size} datapoints into #{output_csv}"
