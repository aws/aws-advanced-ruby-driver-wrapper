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

require 'aws_ruby_driver_wrapper/db_dialects/rds_pg_dialect'

RSpec.describe AwsRubyDriverWrapper::DbDialects::RdsPgDialect do
  let(:driver_dialect) { AwsRubyDriverWrapper::DriverDialects::PgDriverDialect.new }
  subject(:dialect) { described_class.new(driver_dialect) }

  let(:connection) { instance_double('PG::Connection') }

  describe '#dialect?' do
    it 'returns true when rds_tools is enabled and aurora_stat_utils is not' do
      pg_proc_result = [{ '?column?' => '1' }]
      extensions_result = [{ 'rds_tools' => 't', 'aurora_stat_utils' => 'f' }]

      allow(connection).to receive(:exec).with(described_class::PG_PROC_EXISTS_QUERY).and_return(pg_proc_result)
      allow(connection).to receive(:exec).with(described_class::EXTENSIONS_EXIST_SQL).and_return(extensions_result)
      expect(dialect.dialect?(connection)).to be true
    end

    it 'returns false when both rds_tools and aurora_stat_utils are enabled (Aurora)' do
      pg_proc_result = [{ '?column?' => '1' }]
      extensions_result = [{ 'rds_tools' => 't', 'aurora_stat_utils' => 't' }]

      allow(connection).to receive(:exec).with(described_class::PG_PROC_EXISTS_QUERY).and_return(pg_proc_result)
      allow(connection).to receive(:exec).with(described_class::EXTENSIONS_EXIST_SQL).and_return(extensions_result)
      expect(dialect.dialect?(connection)).to be false
    end

    it 'returns false when rds_tools is not enabled' do
      pg_proc_result = [{ '?column?' => '1' }]
      extensions_result = [{ 'rds_tools' => 'f', 'aurora_stat_utils' => 'f' }]

      allow(connection).to receive(:exec).with(described_class::PG_PROC_EXISTS_QUERY).and_return(pg_proc_result)
      allow(connection).to receive(:exec).with(described_class::EXTENSIONS_EXIST_SQL).and_return(extensions_result)
      expect(dialect.dialect?(connection)).to be false
    end

    it 'returns false when pg_proc does not exist' do
      allow(connection).to receive(:exec).with(described_class::PG_PROC_EXISTS_QUERY).and_return([])
      expect(dialect.dialect?(connection)).to be false
    end

    it 'returns false on error' do
      allow(connection).to receive(:exec).and_raise(StandardError)
      expect(dialect.dialect?(connection)).to be false
    end
  end

  describe '#dialect_update_candidates' do
    it 'returns the expected candidates' do
      expect(dialect.dialect_update_candidates).to include(
        AwsRubyDriverWrapper::DialectCodes::MULTI_AZ_PG_CLUSTER,
        AwsRubyDriverWrapper::DialectCodes::GLOBAL_AURORA_PG,
        AwsRubyDriverWrapper::DialectCodes::AURORA_PG
      )
    end
  end

  describe '#blue_green_status_available?' do
    it 'returns true when show_topology function exists' do
      result = [{ 'regproc' => 'show_topology' }]
      allow(connection).to receive(:exec).with(described_class::TOPOLOGY_TABLE_EXISTS_QUERY).and_return(result)
      expect(dialect.blue_green_status_available?(connection)).to be true
    end

    it 'returns false when show_topology function does not exist' do
      allow(connection).to receive(:exec).with(described_class::TOPOLOGY_TABLE_EXISTS_QUERY).and_raise(StandardError)
      expect(dialect.blue_green_status_available?(connection)).to be false
    end
  end
end
