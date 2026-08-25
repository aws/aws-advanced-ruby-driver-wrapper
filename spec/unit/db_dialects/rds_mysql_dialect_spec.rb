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

require 'aws_ruby_database_driver_wrapper/db_dialects/rds_mysql_dialect'

RSpec.describe AwsRubyDatabaseDriverWrapper::DbDialects::RdsMysqlDialect do
  let(:driver_dialect) { AwsRubyDatabaseDriverWrapper::DriverDialects::MysqlDriverDialect.new }
  subject(:dialect) { described_class.new(driver_dialect) }

  let(:connection) { instance_double('Mysql2::Client', closed?: false) }

  describe '#dialect?' do
    it 'returns true for RDS MySQL with Source distribution and empty report_host' do
      version_result = [{ 'Variable_name' => 'version_comment', 'Value' => 'Source distribution' }]
      report_host_result = [{ 'Variable_name' => 'report_host', 'Value' => '' }]

      allow(connection).to receive(:query).with(described_class::VERSION_QUERY).and_return(version_result)
      allow(connection).to receive(:query).with(described_class::REPORT_HOST_EXISTS_QUERY).and_return(report_host_result)
      expect(dialect.dialect?(connection)).to be true
    end

    it 'returns false when version_comment contains mysql (base dialect matches)' do
      version_result = [{ 'Variable_name' => 'version_comment', 'Value' => 'MySQL Community Server (GPL)' }]
      allow(connection).to receive(:query).with(described_class::VERSION_QUERY).and_return(version_result)
      expect(dialect.dialect?(connection)).to be false
    end

    it 'returns false when version_comment is not Source distribution' do
      version_result = [{ 'Variable_name' => 'version_comment', 'Value' => '460f6067' }]
      allow(connection).to receive(:query).with(described_class::VERSION_QUERY).and_return(version_result)
      expect(dialect.dialect?(connection)).to be false
    end

    it 'returns false when report_host is not empty (Multi-AZ cluster)' do
      version_result = [{ 'Variable_name' => 'version_comment', 'Value' => 'Source distribution' }]
      report_host_result = [{ 'Variable_name' => 'report_host', 'Value' => '10.20.0.148' }]

      allow(connection).to receive(:query).with(described_class::VERSION_QUERY).and_return(version_result)
      allow(connection).to receive(:query).with(described_class::REPORT_HOST_EXISTS_QUERY).and_return(report_host_result)
      expect(dialect.dialect?(connection)).to be false
    end

    it 'returns false on error' do
      allow(connection).to receive(:query).and_raise(StandardError)
      expect(dialect.dialect?(connection)).to be false
    end
  end

  describe '#dialect_update_candidates' do
    it 'returns the expected candidates' do
      expect(dialect.dialect_update_candidates).to include(
        AwsRubyDatabaseDriverWrapper::DialectCodes::AURORA_MYSQL,
        AwsRubyDatabaseDriverWrapper::DialectCodes::GLOBAL_AURORA_MYSQL,
        AwsRubyDatabaseDriverWrapper::DialectCodes::MULTI_AZ_MYSQL_CLUSTER
      )
    end
  end

  describe '#blue_green_status_available?' do
    it 'returns true when topology table exists' do
      result = [{ 'tmp' => 1 }]
      allow(connection).to receive(:query).with(described_class::TOPOLOGY_TABLE_EXISTS_QUERY).and_return(result)
      expect(dialect.blue_green_status_available?(connection)).to be true
    end

    it 'returns false when topology table does not exist' do
      allow(connection).to receive(:query).with(described_class::TOPOLOGY_TABLE_EXISTS_QUERY).and_return([])
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
end
