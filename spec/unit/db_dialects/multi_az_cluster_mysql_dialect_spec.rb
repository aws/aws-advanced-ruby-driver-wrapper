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

require 'aws_ruby_database_driver_wrapper/db_dialects/multi_az_cluster_mysql_dialect'

RSpec.describe AwsRubyDatabaseDriverWrapper::DbDialects::MultiAzClusterMysqlDialect do
  let(:driver_dialect) { AwsRubyDatabaseDriverWrapper::DriverDialects::MysqlDriverDialect.new }
  subject(:dialect) { described_class.new(driver_dialect) }

  let(:connection) { instance_double('Mysql2::Client', closed?: false) }

  describe '#dialect?' do
    it 'returns true when topology table exists, has data, and report_host is not empty' do
      topology_table_result = [{ 'tmp' => 1 }]
      topology_result = [
        { 'instance_id' => 443_677_495, 'endpoint' => 'cluster-instance-1.xxxxxxxx.us-east-2.rds.amazonaws.com', 'port' => 3306 },
        { 'instance_id' => 744_033_784, 'endpoint' => 'cluster-instance-3.xxxxxxxx.us-east-2.rds.amazonaws.com', 'port' => 3306 },
        { 'instance_id' => 2_062_424_775, 'endpoint' => 'cluster-instance-2.xxxxxxxx.us-east-2.rds.amazonaws.com', 'port' => 3306 }
      ]
      report_host_result = [{ 'Variable_name' => 'report_host', 'Value' => '10.20.0.148' }]

      allow(connection).to receive(:query).with(described_class::TOPOLOGY_TABLE_EXISTS_QUERY).and_return(topology_table_result)
      allow(connection).to receive(:query).with(described_class::TOPOLOGY_QUERY).and_return(topology_result)
      allow(connection).to receive(:query).with(described_class::REPORT_HOST_EXISTS_QUERY).and_return(report_host_result)
      expect(dialect.dialect?(connection)).to be true
    end

    it 'returns false when topology table does not exist' do
      allow(connection).to receive(:query).with(described_class::TOPOLOGY_TABLE_EXISTS_QUERY).and_return([])
      expect(dialect.dialect?(connection)).to be false
    end

    it 'returns false when topology query returns empty' do
      topology_table_result = [{ 'tmp' => 1 }]
      allow(connection).to receive(:query).with(described_class::TOPOLOGY_TABLE_EXISTS_QUERY).and_return(topology_table_result)
      allow(connection).to receive(:query).with(described_class::TOPOLOGY_QUERY).and_return([])
      expect(dialect.dialect?(connection)).to be false
    end

    it 'returns false when report_host is empty' do
      topology_table_result = [{ 'tmp' => 1 }]
      topology_result = [
        { 'instance_id' => 443_677_495, 'endpoint' => 'cluster-instance-1.example.com', 'port' => 3306 }
      ]
      report_host_result = [{ 'Variable_name' => 'report_host', 'Value' => '' }]

      allow(connection).to receive(:query).with(described_class::TOPOLOGY_TABLE_EXISTS_QUERY).and_return(topology_table_result)
      allow(connection).to receive(:query).with(described_class::TOPOLOGY_QUERY).and_return(topology_result)
      allow(connection).to receive(:query).with(described_class::REPORT_HOST_EXISTS_QUERY).and_return(report_host_result)
      expect(dialect.dialect?(connection)).to be false
    end

    it 'returns false when report_host is nil' do
      topology_table_result = [{ 'tmp' => 1 }]
      topology_result = [
        { 'instance_id' => 443_677_495, 'endpoint' => 'cluster-instance-1.example.com', 'port' => 3306 }
      ]
      report_host_result = [{ 'Variable_name' => 'report_host', 'Value' => nil }]

      allow(connection).to receive(:query).with(described_class::TOPOLOGY_TABLE_EXISTS_QUERY).and_return(topology_table_result)
      allow(connection).to receive(:query).with(described_class::TOPOLOGY_QUERY).and_return(topology_result)
      allow(connection).to receive(:query).with(described_class::REPORT_HOST_EXISTS_QUERY).and_return(report_host_result)
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
    it 'returns the TOPOLOGY_QUERY constant' do
      expect(dialect.topology_query).to eq(described_class::TOPOLOGY_QUERY)
    end
  end

  describe '#host_id_query' do
    it 'returns the TOPOLOGY_QUERY constant' do
      expect(dialect.topology_query).to eq(described_class::TOPOLOGY_QUERY)
    end
  end

  describe '#writer_id_query' do
    it 'returns the WRITER_ID_QUERY constant' do
      expect(dialect.writer_id_query).to eq(described_class::WRITER_ID_QUERY)
    end
  end

  describe '#writer_id_column_name' do
    it 'returns Source_Server_Id' do
      expect(dialect.writer_id_column_name).to eq('Source_Server_Id')
    end
  end

  describe '#instance_identity' do
    it 'returns the instance identity from query result' do
      result = [{ 'instance_id' => '123456789', 'instance_name' => 'multi-az-cluster-instance-1' }]
      allow(connection).to receive(:query).with(described_class::INSTANCE_IDENTITY_QUERY).and_return(result)
      instance_id, instance_name = dialect.instance_identity(connection)
      expect(instance_id).to eq('123456789')
      expect(instance_name).to eq('multi-az-cluster-instance-1')
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
