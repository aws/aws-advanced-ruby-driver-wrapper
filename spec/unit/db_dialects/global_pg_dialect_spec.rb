# frozen_string_literal: true

#  Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
#
#  Licensed under the Apache License, Version 2.0 (the "License").
#  You may not use this file except in compliance with the License.
#  You may obtain a copy of the License at
#
#  http://www.apache.org/licenses/LICENSE-2.0
#
#  Unless required by applicable law or agreed to in writing, software
#  distributed under the License is distributed on an "AS IS" BASIS,
#  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
#  See the License for the specific language governing permissions and
#  limitations under the License.

require 'aws_advanced_ruby_driver_wrapper/db_dialects/global_pg_dialect'

RSpec.describe AwsAdvancedRubyDriverWrapper::DbDialects::GlobalPgDialect do
  let(:driver_dialect) { AwsAdvancedRubyDriverWrapper::DriverDialects::PgDriverDialect.new }
  subject(:dialect) { described_class.new(driver_dialect) }

  let(:connection) { instance_double('PG::Connection') }

  describe '#dialect?' do
    it 'returns true when aurora_stat_utils is enabled, global functions exist, and region count > 1' do
      aurora_utils_result = [{ 'aurora_stat_utils' => 't' }]
      global_status_result = [{ 'regproc' => 'aurora_global_db_status' }]
      global_instance_result = [{ 'regproc' => 'aurora_global_db_instance_status' }]
      region_count_result = [{ 'count' => '2' }]

      allow(connection).to receive(:exec).with(described_class::AURORA_UTILS_EXIST_QUERY).and_return(aurora_utils_result)
      allow(connection).to receive(:exec).with(described_class::GLOBAL_STATUS_FUNC_EXISTS_QUERY).and_return(global_status_result)
      allow(connection).to receive(:exec).with(described_class::GLOBAL_INSTANCE_STATUS_FUNC_EXISTS_QUERY).and_return(global_instance_result)
      allow(connection).to receive(:exec).with(described_class::REGION_COUNT_QUERY).and_return(region_count_result)
      expect(dialect.dialect?(connection)).to be true
    end

    it 'returns false when region count is 1' do
      aurora_utils_result = [{ 'aurora_stat_utils' => 't' }]
      global_status_result = [{ 'regproc' => 'aurora_global_db_status' }]
      global_instance_result = [{ 'regproc' => 'aurora_global_db_instance_status' }]
      region_count_result = [{ 'count' => '1' }]

      allow(connection).to receive(:exec).with(described_class::AURORA_UTILS_EXIST_QUERY).and_return(aurora_utils_result)
      allow(connection).to receive(:exec).with(described_class::GLOBAL_STATUS_FUNC_EXISTS_QUERY).and_return(global_status_result)
      allow(connection).to receive(:exec).with(described_class::GLOBAL_INSTANCE_STATUS_FUNC_EXISTS_QUERY).and_return(global_instance_result)
      allow(connection).to receive(:exec).with(described_class::REGION_COUNT_QUERY).and_return(region_count_result)
      expect(dialect.dialect?(connection)).to be false
    end

    it 'returns false when aurora_stat_utils is not enabled' do
      aurora_utils_result = [{ 'aurora_stat_utils' => 'f' }]
      allow(connection).to receive(:exec).with(described_class::AURORA_UTILS_EXIST_QUERY).and_return(aurora_utils_result)
      expect(dialect.dialect?(connection)).to be false
    end

    it 'returns false when global status function does not exist' do
      aurora_utils_result = [{ 'aurora_stat_utils' => 't' }]
      allow(connection).to receive(:exec).with(described_class::AURORA_UTILS_EXIST_QUERY).and_return(aurora_utils_result)
      allow(connection).to receive(:exec).with(described_class::GLOBAL_STATUS_FUNC_EXISTS_QUERY).and_raise(StandardError)
      expect(dialect.dialect?(connection)).to be false
    end

    it 'returns false when global instance status function does not exist' do
      aurora_utils_result = [{ 'aurora_stat_utils' => 't' }]
      global_status_result = [{ 'regproc' => 'aurora_global_db_status' }]

      allow(connection).to receive(:exec).with(described_class::AURORA_UTILS_EXIST_QUERY).and_return(aurora_utils_result)
      allow(connection).to receive(:exec).with(described_class::GLOBAL_STATUS_FUNC_EXISTS_QUERY).and_return(global_status_result)
      allow(connection).to receive(:exec).with(described_class::GLOBAL_INSTANCE_STATUS_FUNC_EXISTS_QUERY).and_raise(StandardError)
      expect(dialect.dialect?(connection)).to be false
    end

    it 'returns false on error' do
      allow(connection).to receive(:exec).and_raise(StandardError)
      expect(dialect.dialect?(connection)).to be false
    end
  end

  describe '#dialect_update_candidates' do
    it 'returns empty array' do
      expect(dialect.dialect_update_candidates).to eq([])
    end
  end

  describe '#topology_query' do
    it 'returns the GLOBAL_TOPOLOGY_QUERY constant' do
      expect(dialect.topology_query).to eq(described_class::GLOBAL_TOPOLOGY_QUERY)
    end
  end

  describe '#region_by_instance_id_query' do
    it 'returns the REGION_BY_INSTANCE_ID_QUERY constant' do
      expect(dialect.region_by_instance_id_query).to eq(described_class::REGION_BY_INSTANCE_ID_QUERY)
    end

    it 'uses $1 as the parameter placeholder' do
      expect(dialect.region_by_instance_id_query).to include('$1')
    end
  end
end
