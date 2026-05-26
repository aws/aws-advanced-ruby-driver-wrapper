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

require 'aws_ruby_database_driver_wrapper/db_dialects/pg_dialect'

RSpec.describe AwsRubyDatabaseDriverWrapper::DbDialects::PgDialect do
  let(:driver_dialect) { AwsRubyDatabaseDriverWrapper::DriverDialects::PgDriverDialect.new }
  subject(:dialect) { described_class.new(driver_dialect) }

  let(:connection) { instance_double('PG::Connection') }

  describe '#dialect?' do
    it 'returns true when pg_proc exists' do
      result = [{ '?column?' => '1' }]
      allow(connection).to receive(:exec).with(described_class::PG_PROC_EXISTS_QUERY).and_return(result)
      expect(dialect.dialect?(connection)).to be true
    end

    it 'returns false when result is empty' do
      allow(connection).to receive(:exec).with(described_class::PG_PROC_EXISTS_QUERY).and_return([])
      expect(dialect.dialect?(connection)).to be false
    end

    it 'returns false on error' do
      allow(connection).to receive(:exec).and_raise(StandardError)
      expect(dialect.dialect?(connection)).to be false
    end
  end

  describe '#default_port' do
    it 'returns 5432' do
      expect(dialect.default_port).to eq(5432)
    end
  end

  describe '#dialect_update_candidates' do
    it 'returns the expected candidates' do
      expect(dialect.dialect_update_candidates).to include(
        AwsRubyDatabaseDriverWrapper::DialectCodes::GLOBAL_AURORA_PG,
        AwsRubyDatabaseDriverWrapper::DialectCodes::AURORA_PG,
        AwsRubyDatabaseDriverWrapper::DialectCodes::MULTI_AZ_PG_CLUSTER,
        AwsRubyDatabaseDriverWrapper::DialectCodes::RDS_PG
      )
    end
  end

  describe '#execute' do
    it 'delegates to connection.exec' do
      expect(connection).to receive(:exec).with('SELECT 1').and_return(:result)
      expect(dialect.execute(connection, 'SELECT 1')).to eq(:result)
    end
  end

  describe '#host_alias_query' do
    it 'returns the HOST_ALIAS_QUERY constant' do
      expect(dialect.host_alias_query).to eq(described_class::HOST_ALIAS_QUERY)
    end
  end

  describe '#instance_id' do
    it 'returns the hostname from query result' do
      result = [{ 'instance_name' => '10.0.0.1' }]
      allow(connection).to receive(:exec).with(described_class::HOST_ID_QUERY).and_return(result)
      expect(dialect.instance_id(connection)).to eq('10.0.0.1')
    end

    it 'returns nil when result is empty' do
      allow(connection).to receive(:exec).with(described_class::HOST_ID_QUERY).and_return([])
      expect(dialect.instance_id(connection)).to be_nil
    end

    it 'returns nil on error' do
      allow(connection).to receive(:exec).and_raise(StandardError)
      expect(dialect.instance_id(connection)).to be_nil
    end
  end
end
