# *******************************************************************************
# OpenStudio(R), Copyright (c) Alliance for Sustainable Energy, LLC.
# See also https://openstudio.net/license
# *******************************************************************************

class Variable
  include Mongoid::Document
  include Mongoid::Timestamps

  field :uuid, type: String
  field :_id, type: String, default: -> { uuid || SecureRandom.uuid }
  field :r_index, type: Integer
  field :version_uuid, type: String # pointless at this time
  field :name, type: String # machine name (with attached measure id)
  field :metadata_id, type: String, default: nil # link to dencity taxonomy
  field :display_name, type: String, default: ''
  field :display_name_short, type: String, default: ''
  field :minimum
  field :maximum
  field :mean
  field :modes_value
  field :delta_x_value
  field :stddev_value
  field :lower_bounds_value
  field :upper_bounds_value
  field :uncertainty_type, type: String
  field :units, type: String
  field :discrete_values_and_weights
  field :data_type, type: String
  field :value_type, type: String, default: nil # TODO: merge this with the above?
  field :variable_index, type: Integer # for measure groups
  field :argument_index, type: Integer
  field :objective_function, type: Boolean, default: false
  field :objective_function_index, type: Integer, default: nil
  field :objective_function_group, type: Integer, default: nil
  field :visualize, type: Boolean, default: false
  field :export, type: Boolean, default: false
  field :perturbable, type: Boolean, default: false # if enabled, then it will be perturbed
  field :output, type: Boolean, default: false # is this an output variable for reporting, etc
  field :pivot, type: Boolean, default: false
  # field :pivot_samples # don't type for now -- #NLL DELETE? 6/1/2014
  field :relation_to_output, type: String, default: 'standard' # or can be inverse
  field :static_value, default: nil # don't type this because it can take on anything (other than hashes and arrays)

  field :mapper, type: String                             # UrbanOpt Mapper name
  field :uo_measure, type: String                         # UrbanOpt Measure name
  field :uo_variable, type: Boolean, default: false       # UrbanOpt variable flag
  field :report_file, type: String, default: 'default_scenario_report' # UrbanOpt output report name. 
  field :report, type: String, default: 'scenario_report' # UrbanOpt output report name. either: scenario_report/feature_reports
  field :report_id, type: String, default: ''             # UrbanOpt output report :id. either scenario id name or feature report id number
  field :reporting_periods, type: Integer, default: 0     # UrbanOpt output reporting_periods array index
  field :reopt_category, type: String, default: ''     # UrbanOpt output reopt_category 
  field :var_name, type: String, default: ''              # UrbanOpt output name, ex natural_gas
  field :end_use, type: String, default: ''               # UrbanOpt output end_uses, ex electricity, natural_gas, district_cooling, etc
  field :end_use_category, type: String, default: ''      # UrbanOpt output end_use category, ex heating, cooling, fans, etc
  field :comfort_result_category, type: String, default: '' # UrbanOpt output comfort_result_category, ex time_setpoint_not_met_during_occupied_cooling
  field :distributed_generation_category, type: String, default: '' # UrbanOpt output distributed_generation_category, ex total_solar_pv_kw
    
  # Relationships
  belongs_to :analysis, index: true
  belongs_to :measure, optional: true, index: true
  has_many :preflight_images, dependent: :destroy

  # Indexes
  index({ uuid: 1 }, unique: true)
  #index(id: 1)
  index(name: 1)
  index(r_index: 1)
  index(analysis_id: 1)
  index(analysis_id: 1, uuid: 1)
  index(analysis_id: 1, perturbable: 1)
  index(analysis_id: 1, name: 1)

  # Validations
  # validates_format_of :uuid, :with => /[^0-]+/
  # validates_attachment :seed_zip, content_type: { content_type: "application/zip" }

  # Callbacks
  before_create :set_uuid_from_id
  after_create :verify_uuid
  before_destroy :destroy_preflight_images

  def self.create_from_os_json(analysis_id, os_json)
    var = Variable.where(analysis_id: analysis_id, uuid: os_json['uuid']).first
    if var
      logger.warn("Variable already exists for #{var.name} : #{var.uuid}")
    else
      logger.debug "create new variable for os_json['uuid']"
      var = Variable.find_or_create_by(analysis_id: analysis_id, uuid: os_json['uuid'])
      logger.debug var.inspect
    end

    exclude_fields = ['uuid', 'type']
    os_json.each do |k, v|
      var[k] = v unless exclude_fields.include? k
    end

    # deal with type or any other "excluded" variables from the hash
    var.save!

    var
  end

  # Create an output variable from the Analysis JSON
  def self.create_output_variable(analysis_id, json)
    logger.debug("Adding a new output variable named: '#{json['name']}'")
    if json['name'].nil? || json['name'].empty?      #if name if blank for UrbanOpt Output, make it a uuid.var_name so its unique (similar to measure.variable)
      if json['var_name'] == 'end_uses'              #if var_name is end_uses then name is uuid.end_use_end_use_category
        if json['end_use'] && json['end_use_category']
          json['name'] = "#{SecureRandom.uuid}.#{json['end_use']}_#{json['end_use_category']}"
        else
          raise "var_name == end_uses but end_use and end_use_category are missing. check OSA output_variables"
        end
      elsif json['var_name'] == 'comfort_result'              #if var_name is comfort_result then name is uuid.comfort_result_comfort_result_category
        if json['comfort_result_category']
          json['name'] = "#{SecureRandom.uuid}.#{json['var_name']}_#{json['comfort_result_category']}"
        else
          raise "var_name == comfort_result but comfort_result and comfort_result_category are missing. check OSA output_variables"
        end
      elsif json['var_name'] == 'distributed_generation'              #if var_name is distributed_generation then name is uuid.distributed_generation_distributed_generation_category
        if json['distributed_generation_category']
          json['name'] = "#{SecureRandom.uuid}.#{json['var_name']}_#{json['distributed_generation_category']}"
        else
          raise "var_name == distributed_generation but distributed_generation and distributed_generation_category are missing. check OSA output_variables"
        end        
      else
        json['name'] = "#{SecureRandom.uuid}.#{json['var_name']}"    
      end
    end
    var = Variable.where(analysis_id: analysis_id, name: json['name']).first
    if var
      logger.error "Variable already exists for '#{var.name}'.  This will overwrite old variable; rename"  #this is a duplicate variable name and will overwrite the old variable.  this should be an error
      raise "Variable already exists for '#{var.name}' : '#{var.display_name}'"
    else
      logger.info "Adding a new output variable named: '#{json['name']}'"
      var = Variable.find_or_create_by(analysis_id: analysis_id, name: json['name'])
    end

    # Example JSON from the spreadsheet tool
    # {
    #     display_name: "Total Site Energy Intensity",
    #     display_name_short: "Site EUI",
    #     metadata_id: "total_site_energy_intensity",
    #     name: "standard_report_legacy.total_energy",
    #     units: "MJ/m2",
    #     visualize: false,
    #     export: true,
    #     variable_type: "Double",
    #     objective_function: true,
    #     objective_function_index: 0,
    #     objective_function_target: null,
    #     scaling_factor: null,
    #     objective_function_group: 1
    # },
    var.output = true
    var.display_name = json['display_name'] if json['display_name']
    # Until 12/30/2014 keep providing the display_name option
    var.display_name_short = json['display_name_short'] || json['display_name']
    var.metadata_id = json['metadata_id'] if json['metadata_id']
    var.units = json['units'] if json['units']
    var.visualize = json['visualize'] if json['visualize']
    var.export = json['export'] if json['export']
    var.data_type = json['variable_type'] if json['variable_type']
    var.value_type = json['variable_type'] if json['variable_type']
    var.objective_function = json['objective_function'] if json['objective_function']
    var.objective_function_index = json['objective_function_index'] if json['objective_function_index']
    var['objective_function_target'] = json['objective_function_target'] if json['objective_function_target']
    var['scaling_factor'] = json['scaling_factor'] if json['scaling_factor']
    var['objective_function_group'] = json['objective_function_group'] if json['objective_function_group']
    #set these for UrbanOpt
    var.report_file = json['report_file'] if json['report_file']    
    var['report'] = json['report'] if json['report']
    var['report_id'] = json['report_id'] if json['report_id']
    var['reporting_periods'] = json['reporting_periods'] if json['reporting_periods']
    var['reopt_category'] = json['reopt_category'] if json['reopt_category']
    var['var_name'] = json['var_name'] if json['var_name']
    var['end_use'] = json['end_use'] if json['end_use']
    var['end_use_category'] = json['end_use_category'] if json['end_use_category']
    var['comfort_result_category'] = json['comfort_result_category'] if json['comfort_result_category']
    var['distributed_generation_category'] = json['distributed_generation_category'] if json['distributed_generation_category']
    var.save!
    logger.debug("output variable: '#{var.to_json}'")
    var
  end

  # Create the OS argument/variable
  def self.create_and_assign_to_measure(analysis_id, measure, os_json)
    raise 'Measure ID was not defined' unless measure&.id

    var = Variable.where(analysis_id: analysis_id, measure_id: measure.id, uuid: os_json['uuid']).first
    if var
      raise "Variable already exists for '#{var.name}' : '#{var.uuid}'"
    else
      logger.info("Adding a new variable/argument named: '#{os_json['display_name']}' with UUID '#{os_json['uuid']}'")
      var = Variable.find_or_create_by(analysis_id: analysis_id, measure_id: measure.id, uuid: os_json['uuid'])
    end

    var.measure_id = measure.id

    exclude_fields = ['uuid', 'type', 'argument', 'uncertainty_description']
    os_json.each do |k, v|
      var[k] = v unless exclude_fields.include? k

      # Map these temporary terms ??
      var.perturbable = v if k == 'variable'

      # Set the visualize and export field if perturbable
      if var.perturbable
        var.export = true
        var.visualize = true
      end

      if var['pivot']
        var.export = true
        var.visualize = true
      end

      if k == 'argument'
        # this is main portion of the variable
        exclude_fields_2 = ['uuid', 'version_uuid']
        v.each do |k2, v2|
          var[k2] = v2 unless exclude_fields_2.include? k2
        end
      end

      # if the variable has an uncertainty description, then it needs to be flagged
      # as a perturbable (or pivot) variable
      if k == 'uncertainty_description'
        # need to flatten this
        var['uncertainty_type'] = v['type'] if v['type']
        v['attributes']&.each do |attribute|
          # grab the name of the attribute to append the
          # other characteristics
          attribute['name'] ? att_name = attribute['name'] : att_name = nil
          next unless att_name

          attribute.each do |k2, v2|
            exclude_fields_2 = ['uuid', 'version_uuid']
            var["#{att_name}_#{k2}"] = v2 unless exclude_fields_2.include? k2
          end
        end
      end
    end

    # override the variable name to be the measure name and the argument name
    # note that the measure.name should be unique
    if os_json['variable'] || os_json['pivot']
      # Creates a unique ID for this measure
      logger.info "Setting variable name to: '#{measure.name}.#{os_json['argument']['name']}'"
      var.name = "#{measure.name}.#{os_json['argument']['name']}"
    else
      # Just register a note when this is a static argument
      logger.debug "Static variable argument: '#{measure.name}.#{var.name}'"
      # var.name = "#{measure.name}.#{var.name}"
      # var.name_with_measure = "#{measure.name}.#{var.name}"
    end

    var.save!

    var
  end

  def self.pivots(analysis_id)
    Variable.where(analysis_id: analysis_id, pivot: true).order_by(:name.asc)
  end

  # start with a hash and then create the hash_of_arrays
  # r_session is optional: when nil (e.g. Ruby sampling backend on start_local
  # deployments), integer sequences are generated in Ruby instead of R.
  def self.pivot_array(analysis_id, r_session = nil)
    pivot_variables = Variable.pivots(analysis_id)

    pivot_hash = {}
    pivot_variables.each do |var|
      logger.info "Adding variable '#{var.name}' to pivot list"
      if var.uncertainty_type == 'integer_sequence_uncertain' || var.uncertainty_type == 'integer_sequence'
        logger.info("creating integer sequence for pivot variable by seq(from=#{var.lower_bounds_value}, to=#{var.upper_bounds_value}, by=#{var.modes_value})")
        if r_session.nil?
          values = AnalysisLibrary::Sampling::Distributions.seq(var.lower_bounds_value, var.upper_bounds_value, var.modes_value)
          values = values.map(&:to_i)
          weights = Array.new(values.size, 1.0 / values.size)
        else
          @r = r_session
          @r.command(varlow: var.lower_bounds_value) do
            %{
              values <- as.array(seq(from=#{var.lower_bounds_value}, to=#{var.upper_bounds_value}, by=#{var.modes_value}))
              weights <- rep(1/length(values),length(values))
            }
          end
          values = @r.converse 'values'
          values = values.map(&:to_i)
          weights = @r.converse 'weights'
        end
      else
        logger.info "Mapping pivot #{var.name} with #{var.map_discrete_hash_to_array}"
        values, weights = var.map_discrete_hash_to_array # weights are ignored in pivots
      end
      logger.info "pivot variable values are #{values}"
      pivot_hash[var.uuid] = values
    end

    # if there are multiple pivots, then smash the hash of arrays to form a array of hashes
    pivot_array = AnalysisLibrary::Core.product_hash(pivot_hash)
    # pivot_array = AnalysisLibrary::Core.hash_of_array_to_array_of_hash(pivot_hash)
    logger.info "pivot array is #{pivot_array}"

    pivot_array
  end

  def self.variables(analysis_id)
    Variable.where(analysis_id: analysis_id, perturbable: true).order_by(:name.asc)
  end

  def self.visualizes(analysis_id)
    Variable.where(analysis_id: analysis_id, visualize: true).order_by(:name.asc)
  end

  def self.exports(analysis_id)
    Variable.where(analysis_id: analysis_id, export: true).order_by(:name.asc)
  end

  # Method to get all the variables out in a specific JSON format
  def self.get_variable_data_v2(analysis)
    # get all variables for analysis
    save_fields = [
      :measure_id, :name, :display_name, :display_name_short, :metadata_id, :value_type, :units,
      :perturbable, :pivot, :output, :visualize, :export, :static_value, :minimum, :maximum,
      :objective_function, :objective_function_group, :objective_function_index, :objective_function_target
    ]
    variables = Variable.where(analysis_id: analysis).any_of([{ perturbable: true }, { pivot: true }, { output: true }, { export: true }]).as_json(only: save_fields)

    # Add in some measure information into each of the variables, if it is a variable
    variables.each do |v|
      if v['measure_id']
        m = Measure.find(v['measure_id'])
        v['measure_name'] = m.name
        v['measure_display_name'] = m.display_name
      elsif v['name']&.include?('.')
        tmp_name = v['name'].split('.')[0]
        # Test if this is a measure, if so grab that information
        m = Measure.where(name: tmp_name).first
        if m
          v['measure_id'] = m._id
          v['measure_name'] = m.name
          v['measure_display_name'] = m.display_name
        else
          v['measure_id'] = nil
          v['measure_name'] = tmp_name
          v['measure_display_name'] = nil
        end
      else
        v['measure_id'] = nil
        v['measure_name'] = nil
        v['measure_display_name'] = nil
      end

      # variable = Variable.find(k)
      if v['perturbable']
        v['type_of_variable'] = 'variable'
      elsif v['pivot']
        v['type_of_variable'] = 'pivot'
      elsif v['static']
        v['type_of_variable'] = 'static'
      elsif v['output']
        v['type_of_variable'] = 'output'
      else
        v['type_of_variable'] = 'unknown'
      end
    end

    variables
  end

  def map_discrete_hash_to_array
    logger.debug "received map discrete values with #{discrete_values_and_weights} with size #{discrete_values_and_weights.size}"
    ave_weight = (1.0 / discrete_values_and_weights.size)
    logger.debug "average weight is #{ave_weight}"
    discrete_values_and_weights.each_index do |i|
      unless discrete_values_and_weights[i].key? 'weight'
        discrete_values_and_weights[i]['weight'] = ave_weight
      end
    end
    values = discrete_values_and_weights.map { |k| k['value'] }
    weights = discrete_values_and_weights.map { |k| k['weight'] }
    logger.debug "Set values and weights to  #{values} with size #{weights}"

    [values, weights]
  end

  protected

  def set_uuid_from_id
    self.uuid = id
  end
  
  def verify_uuid
    self.uuid = id if uuid.nil?
    save!
  end

  def destroy_preflight_images
    preflight_images.destroy_all
  end
end
