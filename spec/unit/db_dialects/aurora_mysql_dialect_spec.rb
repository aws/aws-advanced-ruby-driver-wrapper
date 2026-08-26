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

require 'aws_ruby_driver_wrapper/db_dialects/aurora_mysql_dialect'

RSpec.describe AwsRubyDriverWrapper::DbDialects::AuroraMysqlDialect do
  let(:driver_dialect) { AwsRubyDriverWrapper::DriverDialects::MysqlDriverDialect.new }
  subject(:dialect) { described_class.new(driver_dialect) }

  let(:connection) { instance_double('Mysql2::Client', closed?: false) }

  describe '#dialect?' do
    it 'returns true when aurora_version variable exists' do
      result = [{ 'Variable_name' => 'aurora_version', 'Value' => '3.11.1' }]
      allow(connection).to receive(:query).with(described_class::AURORA_VERSION_EXISTS_QUERY).and_return(result)
      expect(dialect.dialect?(connection)).to be true
    end

    it 'returns false when aurora_version variable does not exist' do
      allow(connection).to receive(:query).with(described_class::AURORA_VERSION_EXISTS_QUERY).and_return([])
      expect(dialect.dialect?(connection)).to be false
    end

    it 'returns false when query raises an error' do
      allow(connection).to receive(:query).and_raise(StandardError)
      expect(dialect.dialect?(connection)).to be false
    end
  end

  describe '#dialect_update_candidates' do
    it 'returns the expected candidates' do
      expect(dialect.dialect_update_candidates).to include(
        AwsRubyDriverWrapper::DialectCodes::GLOBAL_AURORA_MYSQL,
        AwsRubyDriverWrapper::DialectCodes::MULTI_AZ_MYSQL_CLUSTER
      )
    end
  end

  describe '#topology_query' do
    it 'returns the TOPOLOGY_QUERY constant' do
      expect(dialect.topology_query).to eq(described_class::TOPOLOGY_QUERY)
    end
  end

  describe '#writer_id_query' do
    it 'returns the WRITER_ID_QUERY constant' do
      expect(dialect.writer_id_query).to eq(described_class::WRITER_ID_QUERY)
    end
  end

  describe '#writer_id_query' do
    it 'returns the WRITER_ID_QUERY constant' do
      expect(dialect.writer_id_query).to eq(described_class::WRITER_ID_QUERY)
    end
  end

  describe '#blue_green_status_available?' do
    it 'returns true when topology table exists' do
      result = [{ 'tmp' => 1 }]
      allow(connection).to receive(:query).with(described_class::BG_TOPOLOGY_EXISTS_QUERY).and_return(result)
      expect(dialect.blue_green_status_available?(connection)).to be true
    end

    it 'returns false when topology table does not exist' do
      allow(connection).to receive(:query).with(described_class::BG_TOPOLOGY_EXISTS_QUERY).and_return([])
      expect(dialect.blue_green_status_available?(connection)).to be false
    end

    it 'returns false on error' do
      allow(connection).to receive(:query).and_raise(StandardError)
      expect(dialect.blue_green_status_available?(connection)).to be false
    end
  end

  describe '#blue_green_status_query' do
    it 'returns the BG_STATUS_QUERY constant' do
      expect(dialect.blue_green_status_query).to eq(described_class::BG_STATUS_QUERY)
    end
  end

  describe '#instance_identity' do
    it 'returns the aurora server id' do
      result = [{ 'instance_id' => 'aurora-instance-1', 'instance_name' => 'aurora-instance-1' }]
      allow(connection).to receive(:query).with(described_class::INSTANCE_IDENTITY_QUERY).and_return(result)
      instance_id, instance_name = dialect.instance_identity(connection)
      expect(instance_id).to eq('aurora-instance-1')
      expect(instance_name).to eq('aurora-instance-1')
    end

    it 'returns nil when result is empty' do
      allow(connection).to receive(:query).with(described_class::INSTANCE_IDENTITY_QUERY).and_return([])
      expect(dialect.instance_identity(connection)).to be_nil
    end

    it 'returns nil on error' do
      allow(connection).to receive(:query).and_raise(StandardError)
      expect(dialect.instance_identity(connection)).to be_nil
    end
  end
end
