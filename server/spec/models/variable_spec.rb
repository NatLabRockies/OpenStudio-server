# *******************************************************************************
# OpenStudio(R), Copyright (c) Alliance for Sustainable Energy, LLC.
# See also https://openstudio.net/license
# *******************************************************************************

require 'rails_helper'

RSpec.describe Variable, type: :model do
  # Measure.create_from_os_json looks up measure.variables for each argument; without this
  # index each lookup scans the whole variables collection.
  it 'declares an index on measure_id' do
    keys = Variable.index_specifications.map { |s| s.key.transform_keys(&:to_s) }
    expect(keys).to include('measure_id' => 1)
  end
end
