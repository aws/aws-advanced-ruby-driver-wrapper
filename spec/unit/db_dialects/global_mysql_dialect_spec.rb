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

require 'aws_ruby_driver_wrapper/db_dialects/global_mysql_dialect'

RSpec.describe AwsRubyDriverWrapper::DbDialects::GlobalMysqlDialect do
  let(:driver_dialect) { AwsRubyDriverWrapper::DriverDialects::MysqlDriverDialect.new }
  subject(:dialect) { described_class.new(driver_dialect) }

  let(:connection) { instance_double('Mysql2::Client', closed?: false) }

  describe '#dialect?' do
    it 'returns true when global tables exist and region count > 1' do
      status_result = [{ 'tmp' => 1 }]
      instance_status_result = [{ 'tmp' => 1 }]
      region_count_result = [{ 'count(1)' => 2 }]

      allow(connection).to receive(:query).with(described_class::GLOBAL_STATUS_TABLE_EXISTS_QUERY).and_return(status_result)
      allow(connection).to receive(:query).with(described_class::GLOBAL_INSTANCE_STATUS_EXISTS_QUERY).and_return(instance_status_result)
      allow(connection).to receive(:query).with(described_class::REGION_COUNT_QUERY).and_return(region_count_result)
      expect(dialect.dialect?(connection)).to be true
    end

    it 'returns false when region count is 1' do
      status_result = [{ 'tmp' => 1 }]
      instance_status_result = [{ 'tmp' => 1 }]
      region_count_result = [{ 'count(1)' => 1 }]

      allow(connection).to receive(:query).with(described_class::GLOBAL_STATUS_TABLE_EXISTS_QUERY).and_return(status_result)
      allow(connection).to receive(:query).with(described_class::GLOBAL_INSTANCE_STATUS_EXISTS_QUERY).and_return(instance_status_result)
      allow(connection).to receive(:query).with(described_class::REGION_COUNT_QUERY).and_return(region_count_result)
      expect(dialect.dialect?(connection)).to be false
    end

    it 'returns false when global status table does not exist' do
      allow(connection).to receive(:query).with(described_class::GLOBAL_STATUS_TABLE_EXISTS_QUERY).and_return([])
      expect(dialect.dialect?(connection)).to be false
    end

    it 'returns false when global instance status table does not exist' do
      status_result = [{ 'tmp' => 1 }]
      allow(connection).to receive(:query).with(described_class::GLOBAL_STATUS_TABLE_EXISTS_QUERY).and_return(status_result)
      allow(connection).to receive(:query).with(described_class::GLOBAL_INSTANCE_STATUS_EXISTS_QUERY).and_return([])
      expect(dialect.dialect?(connection)).to be false
    end

    it 'returns false on error' do
      allow(connection).to receive(:query).and_raise(StandardError)
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
  end
end
