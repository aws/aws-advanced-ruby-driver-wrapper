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

require 'aws_advanced_ruby_driver_wrapper/db_dialects/mysql_dialect'

RSpec.describe AwsAdvancedRubyDriverWrapper::DbDialects::MysqlDialect do
  let(:driver_dialect) { AwsAdvancedRubyDriverWrapper::DriverDialects::MysqlDriverDialect.new }
  subject(:dialect) { described_class.new(driver_dialect) }

  let(:connection) { instance_double('Mysql2::Client', closed?: false) }

  describe '#dialect?' do
    it 'returns true when version_comment contains mysql' do
      result = [{ 'Variable_name' => 'version_comment', 'Value' => 'MySQL Community Server (GPL)' }]
      allow(connection).to receive(:query).with(described_class::VERSION_QUERY).and_return(result)
      expect(dialect.dialect?(connection)).to be true
    end

    it 'returns true when version_comment is Source distribution' do
      result = [{ 'Variable_name' => 'version_comment', 'Value' => 'Source distribution' }]
      allow(connection).to receive(:query).with(described_class::VERSION_QUERY).and_return(result)
      expect(dialect.dialect?(connection)).to be false
    end

    it 'returns false when version_comment does not contain mysql' do
      result = [{ 'Variable_name' => 'version_comment', 'Value' => 'MariaDB Server' }]
      allow(connection).to receive(:query).with(described_class::VERSION_QUERY).and_return(result)
      expect(dialect.dialect?(connection)).to be false
    end

    it 'returns false when query raises an error' do
      allow(connection).to receive(:query).and_raise(StandardError)
      expect(dialect.dialect?(connection)).to be false
    end

    it 'returns false when result is empty' do
      allow(connection).to receive(:query).with(described_class::VERSION_QUERY).and_return([])
      expect(dialect.dialect?(connection)).to be false
    end
  end

  describe '#default_port' do
    it 'returns 3306' do
      expect(dialect.default_port).to eq(3306)
    end
  end

  describe '#dialect_update_candidates' do
    it 'returns the expected candidates' do
      expect(dialect.dialect_update_candidates).to include(
        AwsAdvancedRubyDriverWrapper::DialectCodes::AURORA_MYSQL,
        AwsAdvancedRubyDriverWrapper::DialectCodes::RDS_MYSQL,
        AwsAdvancedRubyDriverWrapper::DialectCodes::MULTI_AZ_MYSQL_CLUSTER,
        AwsAdvancedRubyDriverWrapper::DialectCodes::GLOBAL_AURORA_MYSQL
      )
    end
  end

  describe '#execute' do
    it 'delegates to connection.query' do
      expect(connection).to receive(:query).with('SELECT 1').and_return(:result)
      expect(dialect.execute(connection, 'SELECT 1')).to eq(:result)
    end
  end

  describe '#instance_identity' do
    it 'returns the hostname from query result' do
      result = [{ 'instance_id' => 'ip-10-0-0-1', 'instance_name' => 'ip-10-0-0-1:3306' }]
      allow(connection).to receive(:query).with(described_class::INSTANCE_IDENTITY_QUERY).and_return(result)
      instance_id, instance_name = dialect.instance_identity(connection)
      expect(instance_id).to eq('ip-10-0-0-1')
      expect(instance_name).to eq('ip-10-0-0-1:3306')
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
