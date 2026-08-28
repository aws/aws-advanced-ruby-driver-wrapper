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

require 'aws_advanced_ruby_driver_wrapper/db_dialects/multi_az_cluster_pg_dialect'

RSpec.describe AwsAdvancedRubyDriverWrapper::DbDialects::MultiAzClusterPgDialect do
  let(:driver_dialect) { AwsAdvancedRubyDriverWrapper::DriverDialects::PgDriverDialect.new }
  subject(:dialect) { described_class.new(driver_dialect) }

  let(:connection) { instance_double('PG::Connection') }

  describe '#dialect?' do
    it 'returns true when IS_RDS_CLUSTER_QUERY returns a non-nil resource id' do
      result = [{ 'multi_az_db_cluster_source_dbi_resource_id' => 'db-XXXXXXXXXXXXXXXXXXXXXXXXXX' }]
      allow(connection).to receive(:exec).with(described_class::IS_RDS_CLUSTER_QUERY).and_return(result)
      expect(dialect.dialect?(connection)).to be true
    end

    it 'returns false when resource id is nil' do
      result = [{ 'multi_az_db_cluster_source_dbi_resource_id' => nil }]
      allow(connection).to receive(:exec).with(described_class::IS_RDS_CLUSTER_QUERY).and_return(result)
      expect(dialect.dialect?(connection)).to be false
    end

    it 'returns false when result is empty' do
      allow(connection).to receive(:exec).with(described_class::IS_RDS_CLUSTER_QUERY).and_return([])
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
    it 'returns multi_az_db_cluster_source_dbi_resource_id' do
      expect(dialect.writer_id_column_name).to eq('multi_az_db_cluster_source_dbi_resource_id')
    end
  end

  describe '#instance_identity' do
    it 'returns the instance name from query result' do
      result = [{ 'instance_id' => '123456789', 'instance_name' => 'instance-1' }]
      allow(connection).to receive(:exec).with(described_class::INSTANCE_IDENTITY_QUERY).and_return(result)
      instance_id, instance_name = dialect.instance_identity(connection)
      expect(instance_id).to eq('123456789')
      expect(instance_name).to eq('instance-1')
    end

    it 'returns nil when result is empty' do
      allow(connection).to receive(:exec).with(described_class::INSTANCE_IDENTITY_QUERY).and_return([])
      expect(dialect.instance_identity(connection)).to be_nil
    end

    it 'returns nil on error' do
      allow(connection).to receive(:exec).and_raise(StandardError)
      expect(dialect.instance_identity(connection)).to be_nil
    end
  end
end
