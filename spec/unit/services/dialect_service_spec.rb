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

require_relative '../../spec_helper'
require 'aws_ruby_database_driver_wrapper/services/dialect_service'
require 'aws_ruby_database_driver_wrapper/utils/connection_config'
require 'aws_ruby_database_driver_wrapper/host/host_info'

RSpec.describe AwsRubyDatabaseDriverWrapper::Services::DialectService do
  let(:dialect_codes) { AwsRubyDatabaseDriverWrapper::DialectCodes }

  before do
    # Clear the endpoint cache between tests to avoid cross-test contamination
    described_class.known_endpoint_dialects.clear
  end

  def build_config(host:, wrapper_props: {}, driver_props: {})
    host_info = AwsRubyDatabaseDriverWrapper::Host::HostInfo.new(host: host)
    AwsRubyDatabaseDriverWrapper::Utils::ConnectionConfig.new(
      driver_props: driver_props.merge(host: host),
      wrapper_props: wrapper_props,
      initial_host_info: host_info
    )
  end

  describe '#initialize' do
    it 'sets the driver dialect for postgresql' do
      service = described_class.new(:postgresql)
      expect(service.driver_dialect).to be_a(AwsRubyDatabaseDriverWrapper::DriverDialects::PgDriverDialect)
    end

    it 'sets the driver dialect for mysql2' do
      service = described_class.new(:mysql2)
      expect(service.driver_dialect).to be_a(AwsRubyDatabaseDriverWrapper::DriverDialects::MysqlDriverDialect)
    end

    it 'raises an error for unknown driver' do
      expect { described_class.new(:unknown) }
        .to raise_error(AwsRubyDatabaseDriverWrapper::Errors::AwsError, /Unknown driver/)
    end
  end

  describe '#get_dialect' do
    context 'PostgreSQL driver' do
      subject(:service) { described_class.new(:postgresql) }

      it 'returns AuroraPgDialect for Aurora writer cluster endpoint' do
        config = build_config(host: 'my-cluster.cluster-xyz.us-east-2.rds.amazonaws.com')
        service.get_dialect(config)
        expect(service.db_dialect).to be_a(AwsRubyDatabaseDriverWrapper::DbDialects::AuroraPgDialect)
      end

      it 'returns AuroraPgDialect for Aurora reader cluster endpoint' do
        config = build_config(host: 'my-cluster.cluster-ro-xyz.us-east-2.rds.amazonaws.com')
        service.get_dialect(config)
        expect(service.db_dialect).to be_a(AwsRubyDatabaseDriverWrapper::DbDialects::AuroraPgDialect)
      end

      it 'returns GlobalPgDialect for global writer cluster endpoint' do
        config = build_config(host: 'my-global.global-xyz.global.rds.amazonaws.com')
        service.get_dialect(config)
        expect(service.db_dialect).to be_a(AwsRubyDatabaseDriverWrapper::DbDialects::GlobalPgDialect)
      end

      it 'returns AuroraPgDialect for limitless shard group endpoint' do
        config = build_config(host: 'my-db.shardgrp-xyz.us-east-2.rds.amazonaws.com')
        service.get_dialect(config)
        expect(service.db_dialect).to be_a(AwsRubyDatabaseDriverWrapper::DbDialects::AuroraPgDialect)
      end

      it 'returns RdsPgDialect for RDS instance endpoint' do
        config = build_config(host: 'my-instance.xyz.us-east-2.rds.amazonaws.com')
        service.get_dialect(config)
        expect(service.db_dialect).to be_a(AwsRubyDatabaseDriverWrapper::DbDialects::RdsPgDialect)
      end

      it 'returns PgDialect for non-RDS endpoint' do
        config = build_config(host: 'my-database.example.com')
        service.get_dialect(config)
        expect(service.db_dialect).to be_a(AwsRubyDatabaseDriverWrapper::DbDialects::PgDialect)
      end

      it 'returns PgDialect for IP address' do
        config = build_config(host: '192.168.1.1')
        service.get_dialect(config)
        expect(service.db_dialect).to be_a(AwsRubyDatabaseDriverWrapper::DbDialects::PgDialect)
      end
    end

    context 'MySQL driver' do
      subject(:service) { described_class.new(:mysql2) }

      it 'returns AuroraMysqlDialect for Aurora writer cluster endpoint' do
        config = build_config(host: 'my-cluster.cluster-xyz.us-east-2.rds.amazonaws.com')
        service.get_dialect(config)
        expect(service.db_dialect).to be_a(AwsRubyDatabaseDriverWrapper::DbDialects::AuroraMysqlDialect)
      end

      it 'returns AuroraMysqlDialect for Aurora reader cluster endpoint' do
        config = build_config(host: 'my-cluster.cluster-ro-xyz.us-east-2.rds.amazonaws.com')
        service.get_dialect(config)
        expect(service.db_dialect).to be_a(AwsRubyDatabaseDriverWrapper::DbDialects::AuroraMysqlDialect)
      end

      it 'returns GlobalMysqlDialect for global writer cluster endpoint' do
        config = build_config(host: 'my-global.global-xyz.global.rds.amazonaws.com')
        service.get_dialect(config)
        expect(service.db_dialect).to be_a(AwsRubyDatabaseDriverWrapper::DbDialects::GlobalMysqlDialect)
      end

      it 'returns RdsMysqlDialect for RDS instance endpoint' do
        config = build_config(host: 'my-instance.xyz.us-east-2.rds.amazonaws.com')
        service.get_dialect(config)
        expect(service.db_dialect).to be_a(AwsRubyDatabaseDriverWrapper::DbDialects::RdsMysqlDialect)
      end

      it 'returns MysqlDialect for non-RDS endpoint' do
        config = build_config(host: 'my-database.example.com')
        service.get_dialect(config)
        expect(service.db_dialect).to be_a(AwsRubyDatabaseDriverWrapper::DbDialects::MysqlDialect)
      end

      it 'returns MysqlDialect for IP address' do
        config = build_config(host: '10.0.0.1')
        service.get_dialect(config)
        expect(service.db_dialect).to be_a(AwsRubyDatabaseDriverWrapper::DbDialects::MysqlDialect)
      end
    end

    context 'with cached endpoint dialect' do
      subject(:service) { described_class.new(:postgresql) }

      it 'returns cached dialect on subsequent calls for the same host' do
        host = 'cached-cluster.cluster-xyz.us-east-2.rds.amazonaws.com'
        config = build_config(host: host)

        # First call resolves via RDS type
        service.get_dialect(config)
        expect(service.db_dialect).to be_a(AwsRubyDatabaseDriverWrapper::DbDialects::AuroraPgDialect)

        # Manually cache the dialect to simulate what update_dialect would do
        described_class.known_endpoint_dialects.put(host, AwsRubyDatabaseDriverWrapper::DialectCodes::AURORA_PG)

        # Second service instance should pick up the cached dialect
        service2 = described_class.new(:postgresql)
        service2.get_dialect(config)
        expect(service2.db_dialect).to be_a(AwsRubyDatabaseDriverWrapper::DbDialects::AuroraPgDialect)
      end
    end

    context 'with user-specified dialect' do
      subject(:service) { described_class.new(:postgresql) }

      it 'uses the user-specified dialect code' do
        config = build_config(
          host: 'my-database.example.com',
          wrapper_props: { wrapper_dialect: dialect_codes::AURORA_PG }
        )
        service.get_dialect(config)
        expect(service.db_dialect).to be_a(AwsRubyDatabaseDriverWrapper::DbDialects::AuroraPgDialect)
      end

      it 'raises an error for an invalid user-specified dialect code' do
        config = build_config(
          host: 'my-database.example.com',
          wrapper_props: { wrapper_dialect: 'nonexistent-dialect' }
        )
        expect { service.get_dialect(config) }
          .to raise_error(AwsRubyDatabaseDriverWrapper::Errors::AwsError, /Unknown dialect code/)
      end
    end

    context 'China region endpoints' do
      subject(:service) { described_class.new(:postgresql) }

      it 'returns AuroraPgDialect for China new format cluster endpoint' do
        config = build_config(host: 'my-cluster.cluster-xyz.rds.cn-northwest-1.amazonaws.com.cn')
        service.get_dialect(config)
        expect(service.db_dialect).to be_a(AwsRubyDatabaseDriverWrapper::DbDialects::AuroraPgDialect)
      end

      it 'returns AuroraPgDialect for China old format cluster endpoint' do
        config = build_config(host: 'my-cluster.cluster-xyz.cn-northwest-1.rds.amazonaws.com.cn')
        service.get_dialect(config)
        expect(service.db_dialect).to be_a(AwsRubyDatabaseDriverWrapper::DbDialects::AuroraPgDialect)
      end
    end

    context 'Gov/ISO region endpoints' do
      subject(:service) { described_class.new(:mysql2) }

      it 'returns AuroraMysqlDialect for Gov cluster endpoint' do
        config = build_config(host: 'my-cluster.cluster-xyz.rds.us-gov-east-1.amazonaws.com')
        service.get_dialect(config)
        expect(service.db_dialect).to be_a(AwsRubyDatabaseDriverWrapper::DbDialects::AuroraMysqlDialect)
      end

      it 'returns AuroraMysqlDialect for ISO cluster endpoint' do
        config = build_config(host: 'my-cluster.cluster-xyz.rds.us-iso-east-1.c2s.ic.gov')
        service.get_dialect(config)
        expect(service.db_dialect).to be_a(AwsRubyDatabaseDriverWrapper::DbDialects::AuroraMysqlDialect)
      end
    end

    context 'state reset' do
      subject(:service) { described_class.new(:postgresql) }

      it 'resets db_dialect on each get_dialect call' do
        config1 = build_config(host: 'my-cluster.cluster-xyz.us-east-2.rds.amazonaws.com')
        service.get_dialect(config1)
        expect(service.db_dialect).to be_a(AwsRubyDatabaseDriverWrapper::DbDialects::AuroraPgDialect)

        config2 = build_config(host: 'my-database.example.com')
        service.get_dialect(config2)
        expect(service.db_dialect).to be_a(AwsRubyDatabaseDriverWrapper::DbDialects::PgDialect)
      end

      it 'sets can_update to false for non-updatable dialects' do
        config = build_config(host: 'my-global.global-xyz.global.rds.amazonaws.com')
        service.get_dialect(config)
        expect(service.can_update?).to be false
      end

      it 'sets can_update to true for updatable dialects' do
        config = build_config(host: 'my-cluster.cluster-xyz.us-east-2.rds.amazonaws.com')
        service.get_dialect(config)
        expect(service.can_update?).to be true
      end
    end
  end

  describe '#update_dialect' do
    context 'PostgreSQL driver' do
      subject(:service) { described_class.new(:postgresql) }

      let(:connection) { instance_double('PG::Connection') }
      let(:host) { 'my-cluster.cluster-xyz.us-east-2.rds.amazonaws.com' }
      let(:config) { build_config(host: host) }

      before do
        service.get_dialect(config)
      end

      it 'returns current dialect without updating when not updatable' do
        global_config = build_config(host: 'my-global.global-xyz.global.rds.amazonaws.com')
        service.get_dialect(global_config)
        original_dialect = service.db_dialect

        result = service.update_dialect(global_config, connection)
        expect(result).to eq(original_dialect)
      end

      it 'updates to GlobalPgDialect when global functions exist' do
        aurora_utils_result = [{ 'aurora_stat_utils' => 't' }]
        global_status_result = [{ 'regproc' => 'aurora_global_db_status' }]
        global_instance_result = [{ 'regproc' => 'aurora_global_db_instance_status' }]
        region_count_result = [{ 'count' => '2' }]

        allow(connection).to receive(:exec).and_return([])
        allow(connection).to receive(:exec)
          .with(AwsRubyDatabaseDriverWrapper::DbDialects::GlobalPgDialect::AURORA_UTILS_EXIST_QUERY)
          .and_return(aurora_utils_result)
        allow(connection).to receive(:exec)
          .with(AwsRubyDatabaseDriverWrapper::DbDialects::GlobalPgDialect::GLOBAL_STATUS_FUNC_EXISTS_QUERY)
          .and_return(global_status_result)
        allow(connection).to receive(:exec)
          .with(AwsRubyDatabaseDriverWrapper::DbDialects::GlobalPgDialect::GLOBAL_INSTANCE_STATUS_FUNC_EXISTS_QUERY)
          .and_return(global_instance_result)
        allow(connection).to receive(:exec)
          .with(AwsRubyDatabaseDriverWrapper::DbDialects::GlobalPgDialect::REGION_COUNT_QUERY)
          .and_return(region_count_result)

        result = service.update_dialect(config, connection)
        expect(result).to be_a(AwsRubyDatabaseDriverWrapper::DbDialects::GlobalPgDialect)
      end

      it 'caches the dialect after update' do
        allow(connection).to receive(:exec).and_raise(StandardError)

        service.update_dialect(config, connection)
        expect(described_class.known_endpoint_dialects.get(host)).to eq(AwsRubyDatabaseDriverWrapper::DialectCodes::AURORA_PG)
      end

      it 'caches dialect for both host and host_url on successful candidate match' do
        aurora_utils_result = [{ 'aurora_stat_utils' => 't' }]
        global_status_result = [{ 'regproc' => 'aurora_global_db_status' }]
        global_instance_result = [{ 'regproc' => 'aurora_global_db_instance_status' }]
        region_count_result = [{ 'count' => '2' }]

        allow(connection).to receive(:exec).and_return([])
        allow(connection).to receive(:exec)
          .with(AwsRubyDatabaseDriverWrapper::DbDialects::GlobalPgDialect::AURORA_UTILS_EXIST_QUERY)
          .and_return(aurora_utils_result)
        allow(connection).to receive(:exec)
          .with(AwsRubyDatabaseDriverWrapper::DbDialects::GlobalPgDialect::GLOBAL_STATUS_FUNC_EXISTS_QUERY)
          .and_return(global_status_result)
        allow(connection).to receive(:exec)
          .with(AwsRubyDatabaseDriverWrapper::DbDialects::GlobalPgDialect::GLOBAL_INSTANCE_STATUS_FUNC_EXISTS_QUERY)
          .and_return(global_instance_result)
        allow(connection).to receive(:exec)
          .with(AwsRubyDatabaseDriverWrapper::DbDialects::GlobalPgDialect::REGION_COUNT_QUERY)
          .and_return(region_count_result)

        service.update_dialect(config, connection)

        host_url = config.initial_host_info.url
        expect(described_class.known_endpoint_dialects.get(host)).to eq(AwsRubyDatabaseDriverWrapper::DialectCodes::GLOBAL_AURORA_PG)
        expect(described_class.known_endpoint_dialects.get(host_url)).to eq(AwsRubyDatabaseDriverWrapper::DialectCodes::GLOBAL_AURORA_PG)
      end

      it 'sets can_update to false after update completes without match' do
        allow(connection).to receive(:exec).and_raise(StandardError)

        service.update_dialect(config, connection)
        expect(service.can_update?).to be false
      end

      it 'keeps current dialect when no candidate matches but dialect is not UNKNOWN' do
        allow(connection).to receive(:exec).and_raise(StandardError)

        result = service.update_dialect(config, connection)
        expect(result).to be_a(AwsRubyDatabaseDriverWrapper::DbDialects::AuroraPgDialect)
      end
    end

    context 'MySQL driver' do
      subject(:service) { described_class.new(:mysql2) }

      let(:connection) { instance_double('Mysql2::Client') }
      let(:host) { 'my-cluster.cluster-xyz.us-east-2.rds.amazonaws.com' }
      let(:config) { build_config(host: host) }

      before do
        service.get_dialect(config)
      end

      it 'updates to GlobalMysqlDialect when global tables exist' do
        status_result = [{ 'tmp' => 1 }]
        instance_status_result = [{ 'tmp' => 1 }]
        region_count_result = [{ 'count(1)' => 2 }]

        allow(connection).to receive(:query).and_return([])
        allow(connection).to receive(:query)
          .with(AwsRubyDatabaseDriverWrapper::DbDialects::GlobalMysqlDialect::GLOBAL_STATUS_TABLE_EXISTS_QUERY)
          .and_return(status_result)
        allow(connection).to receive(:query)
          .with(AwsRubyDatabaseDriverWrapper::DbDialects::GlobalMysqlDialect::GLOBAL_INSTANCE_STATUS_EXISTS_QUERY)
          .and_return(instance_status_result)
        allow(connection).to receive(:query)
          .with(AwsRubyDatabaseDriverWrapper::DbDialects::GlobalMysqlDialect::REGION_COUNT_QUERY)
          .and_return(region_count_result)

        result = service.update_dialect(config, connection)
        expect(result).to be_a(AwsRubyDatabaseDriverWrapper::DbDialects::GlobalMysqlDialect)
      end

      it 'keeps AuroraMysqlDialect when no candidate matches' do
        allow(connection).to receive(:query).and_raise(StandardError)

        result = service.update_dialect(config, connection)
        expect(result).to be_a(AwsRubyDatabaseDriverWrapper::DbDialects::AuroraMysqlDialect)
      end

      it 'caches dialect for host after no candidate matches' do
        allow(connection).to receive(:query).and_raise(StandardError)

        service.update_dialect(config, connection)
        expect(described_class.known_endpoint_dialects.get(host)).to eq(AwsRubyDatabaseDriverWrapper::DialectCodes::AURORA_MYSQL)
      end
    end
  end

  describe '#dialect_for_code' do
    subject(:service) { described_class.new(:postgresql) }

    it 'returns the same cached instance on repeated calls' do
      first = service.dialect_for_code(dialect_codes::AURORA_PG)
      second = service.dialect_for_code(dialect_codes::AURORA_PG)
      expect(first).to equal(second)
    end

    it 'returns nil for an unknown dialect code' do
      expect(service.dialect_for_code('nonexistent')).to be_nil
    end
  end

  describe '#network_error?' do
    context 'PostgreSQL' do
      subject(:service) { described_class.new(:postgresql) }

      it 'delegates to the PG error handler' do
        pg_result = instance_double('PG::Result')
        allow(pg_result).to receive(:error_field).with(PG::PG_DIAG_SQLSTATE).and_return('57P01')
        error = PG::Error.new('admin shutdown')
        allow(error).to receive(:result).and_return(pg_result)

        expect(service.network_error?(error)).to be true
      end

      it 'returns false for non-network errors' do
        pg_result = instance_double('PG::Result')
        allow(pg_result).to receive(:error_field).with(PG::PG_DIAG_SQLSTATE).and_return('28000')
        error = PG::Error.new('auth error')
        allow(error).to receive(:result).and_return(pg_result)

        expect(service.network_error?(error)).to be false
      end
    end

    context 'MySQL' do
      subject(:service) { described_class.new(:mysql2) }

      it 'returns true for connection errors' do
        error = Mysql2::Error.allocate
        allow(error).to receive(:sql_state).and_return('08S01')
        expect(service.network_error?(error)).to be true
      end

      it 'returns false for non-network errors' do
        error = Mysql2::Error.allocate
        allow(error).to receive(:sql_state).and_return('28000')
        expect(service.network_error?(error)).to be false
      end
    end
  end

  describe '#login_error?' do
    context 'PostgreSQL' do
      subject(:service) { described_class.new(:postgresql) }

      it 'returns true for invalid password' do
        pg_result = instance_double('PG::Result')
        allow(pg_result).to receive(:error_field).with(PG::PG_DIAG_SQLSTATE).and_return('28P01')
        error = PG::Error.new('invalid password')
        allow(error).to receive(:result).and_return(pg_result)

        expect(service.login_error?(error)).to be true
      end

      it 'returns false for non-login errors' do
        pg_result = instance_double('PG::Result')
        allow(pg_result).to receive(:error_field).with(PG::PG_DIAG_SQLSTATE).and_return('57P01')
        error = PG::Error.new('shutdown')
        allow(error).to receive(:result).and_return(pg_result)

        expect(service.login_error?(error)).to be false
      end
    end

    context 'MySQL' do
      subject(:service) { described_class.new(:mysql2) }

      it 'returns true for access denied' do
        error = Mysql2::Error.allocate
        allow(error).to receive(:sql_state).and_return('28000')
        expect(service.login_error?(error)).to be true
      end
    end
  end

  describe '#read_only_error?' do
    context 'PostgreSQL' do
      subject(:service) { described_class.new(:postgresql) }

      it 'returns true for read-only transaction error' do
        pg_result = instance_double('PG::Result')
        allow(pg_result).to receive(:error_field).with(PG::PG_DIAG_SQLSTATE).and_return('25006')
        error = PG::Error.new('read only')
        allow(error).to receive(:result).and_return(pg_result)

        expect(service.read_only_error?(error)).to be true
      end

      it 'returns false for non-read-only errors' do
        pg_result = instance_double('PG::Result')
        allow(pg_result).to receive(:error_field).with(PG::PG_DIAG_SQLSTATE).and_return('28000')
        error = PG::Error.new('auth')
        allow(error).to receive(:result).and_return(pg_result)

        expect(service.read_only_error?(error)).to be false
      end
    end

    context 'MySQL' do
      subject(:service) { described_class.new(:mysql2) }

      it 'returns true for read-only error code 1290' do
        error = Mysql2::Error.allocate
        allow(error).to receive(:sql_state).and_return('HY000')
        allow(error).to receive(:error_number).and_return(1290)
        expect(service.read_only_error?(error)).to be true
      end
    end
  end
end
