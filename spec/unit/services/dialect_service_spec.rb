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
require 'aws_ruby_database_driver_wrapper/services/connection_service'
require 'aws_ruby_database_driver_wrapper/services/service_container'
require 'aws_ruby_database_driver_wrapper/services/host_service'
require 'aws_ruby_database_driver_wrapper/host/host_info'

RSpec.describe AwsRubyDatabaseDriverWrapper::Services::DialectService do
  let(:dialect_codes) { AwsRubyDatabaseDriverWrapper::DialectCodes }

  before do
    # Clear the endpoint cache between tests to avoid cross-test contamination
    described_class.known_endpoint_dialects.clear
  end

  def build_connection_service(host: 'localhost', wrapper_props: {})
    host_info = AwsRubyDatabaseDriverWrapper::Host::HostInfo.new(host: host)
    instance_double(
      AwsRubyDatabaseDriverWrapper::Services::ConnectionService,
      initial_host_info: host_info,
      wrapper_props: wrapper_props,
      prefixed_wrapper_config: {},
      prefixed_driver_config: {},
      driver_props: { host: host, port: '5432' }
    )
  end

  def build_service(driver_name, host: 'localhost', wrapper_props: {})
    conn_service = build_connection_service(host: host, wrapper_props: wrapper_props)
    described_class.new(conn_service, driver_name)
  end

  def build_service_with_container(driver_name, host: 'localhost', wrapper_props: {})
    conn_service = build_connection_service(host: host, wrapper_props: wrapper_props)
    service = described_class.new(conn_service, driver_name)

    host_list_provider = double('HostListProvider', refresh: [], stop_monitor: nil)
    host_service = double('HostService', host_list_provider: host_list_provider,
                                         'host_list_provider=': nil, refresh_host_list: nil)
    monitor_service = double('MonitorService', register_type: nil)
    storage_service = double('StorageService', register: nil)

    container = AwsRubyDatabaseDriverWrapper::Services::ServiceContainer.new(
      connection_service: conn_service,
      dialect_service: service,
      host_service: host_service,
      monitor_service: monitor_service,
      storage_service: storage_service
    )
    service.setup_initial_provider(container)
    service
  end

  describe '#initialize' do
    it 'sets the driver dialect for postgresql' do
      service = build_service(:postgresql)
      expect(service.driver_dialect).to be_a(AwsRubyDatabaseDriverWrapper::DriverDialects::PgDriverDialect)
    end

    it 'sets the driver dialect for mysql2' do
      service = build_service(:mysql2)
      expect(service.driver_dialect).to be_a(AwsRubyDatabaseDriverWrapper::DriverDialects::MysqlDriverDialect)
    end

    it 'raises an error for unknown driver' do
      expect { build_service(:unknown) }
        .to raise_error(AwsRubyDatabaseDriverWrapper::Errors::AwsError, /Unknown driver/)
    end
  end

  describe '#get_dialect' do
    context 'PostgreSQL driver' do
      it 'returns AuroraPgDialect for Aurora writer cluster endpoint' do
        service = build_service(:postgresql, host: 'my-cluster.cluster-xyz.us-east-2.rds.amazonaws.com')
        expect(service.db_dialect).to be_a(AwsRubyDatabaseDriverWrapper::DbDialects::AuroraPgDialect)
      end

      it 'returns AuroraPgDialect for Aurora reader cluster endpoint' do
        service = build_service(:postgresql, host: 'my-cluster.cluster-ro-xyz.us-east-2.rds.amazonaws.com')
        expect(service.db_dialect).to be_a(AwsRubyDatabaseDriverWrapper::DbDialects::AuroraPgDialect)
      end

      it 'returns GlobalPgDialect for global writer cluster endpoint' do
        service = build_service(:postgresql, host: 'my-global.global-xyz.global.rds.amazonaws.com')
        expect(service.db_dialect).to be_a(AwsRubyDatabaseDriverWrapper::DbDialects::GlobalPgDialect)
      end

      it 'returns AuroraPgDialect for limitless shard group endpoint' do
        service = build_service(:postgresql, host: 'my-db.shardgrp-xyz.us-east-2.rds.amazonaws.com')
        expect(service.db_dialect).to be_a(AwsRubyDatabaseDriverWrapper::DbDialects::AuroraPgDialect)
      end

      it 'returns RdsPgDialect for RDS instance endpoint' do
        service = build_service(:postgresql, host: 'my-instance.xyz.us-east-2.rds.amazonaws.com')
        expect(service.db_dialect).to be_a(AwsRubyDatabaseDriverWrapper::DbDialects::RdsPgDialect)
      end

      it 'returns PgDialect for non-RDS endpoint' do
        service = build_service(:postgresql, host: 'my-database.example.com')
        expect(service.db_dialect).to be_a(AwsRubyDatabaseDriverWrapper::DbDialects::PgDialect)
      end

      it 'returns PgDialect for IP address' do
        service = build_service(:postgresql, host: '192.168.1.1')
        expect(service.db_dialect).to be_a(AwsRubyDatabaseDriverWrapper::DbDialects::PgDialect)
      end
    end

    context 'MySQL driver' do
      it 'returns AuroraMysqlDialect for Aurora writer cluster endpoint' do
        service = build_service(:mysql2, host: 'my-cluster.cluster-xyz.us-east-2.rds.amazonaws.com')
        expect(service.db_dialect).to be_a(AwsRubyDatabaseDriverWrapper::DbDialects::AuroraMysqlDialect)
      end

      it 'returns AuroraMysqlDialect for Aurora reader cluster endpoint' do
        service = build_service(:mysql2, host: 'my-cluster.cluster-ro-xyz.us-east-2.rds.amazonaws.com')
        expect(service.db_dialect).to be_a(AwsRubyDatabaseDriverWrapper::DbDialects::AuroraMysqlDialect)
      end

      it 'returns GlobalMysqlDialect for global writer cluster endpoint' do
        service = build_service(:mysql2, host: 'my-global.global-xyz.global.rds.amazonaws.com')
        expect(service.db_dialect).to be_a(AwsRubyDatabaseDriverWrapper::DbDialects::GlobalMysqlDialect)
      end

      it 'returns RdsMysqlDialect for RDS instance endpoint' do
        service = build_service(:mysql2, host: 'my-instance.xyz.us-east-2.rds.amazonaws.com')
        expect(service.db_dialect).to be_a(AwsRubyDatabaseDriverWrapper::DbDialects::RdsMysqlDialect)
      end

      it 'returns MysqlDialect for non-RDS endpoint' do
        service = build_service(:mysql2, host: 'my-database.example.com')
        expect(service.db_dialect).to be_a(AwsRubyDatabaseDriverWrapper::DbDialects::MysqlDialect)
      end

      it 'returns MysqlDialect for IP address' do
        service = build_service(:mysql2, host: '10.0.0.1')
        expect(service.db_dialect).to be_a(AwsRubyDatabaseDriverWrapper::DbDialects::MysqlDialect)
      end
    end

    context 'with cached endpoint dialect' do
      it 'returns cached dialect on subsequent calls for the same host' do
        host = 'cached-cluster.cluster-xyz.us-east-2.rds.amazonaws.com'

        # First call resolves via RDS type
        service = build_service(:postgresql, host: host)
        expect(service.db_dialect).to be_a(AwsRubyDatabaseDriverWrapper::DbDialects::AuroraPgDialect)

        # Manually cache the dialect to simulate what update_dialect would do
        described_class.known_endpoint_dialects.put(host, AwsRubyDatabaseDriverWrapper::DialectCodes::AURORA_PG)

        # Second service instance should pick up the cached dialect
        service2 = build_service(:postgresql, host: host)
        expect(service2.db_dialect).to be_a(AwsRubyDatabaseDriverWrapper::DbDialects::AuroraPgDialect)
      end
    end

    context 'with user-specified dialect' do
      it 'uses the user-specified dialect code' do
        service = build_service(:postgresql, host: 'my-database.example.com',
                                             wrapper_props: { wrapper_dialect: dialect_codes::AURORA_PG })
        expect(service.db_dialect).to be_a(AwsRubyDatabaseDriverWrapper::DbDialects::AuroraPgDialect)
      end

      it 'raises an error for an invalid user-specified dialect code' do
        expect do
          build_service(:postgresql, host: 'my-database.example.com',
                                     wrapper_props: { wrapper_dialect: 'nonexistent-dialect' })
        end.to raise_error(AwsRubyDatabaseDriverWrapper::Errors::AwsError, /Unknown dialect code/)
      end
    end

    context 'China region endpoints' do
      it 'returns AuroraPgDialect for China new format cluster endpoint' do
        service = build_service(:postgresql, host: 'my-cluster.cluster-xyz.rds.cn-northwest-1.amazonaws.com.cn')
        expect(service.db_dialect).to be_a(AwsRubyDatabaseDriverWrapper::DbDialects::AuroraPgDialect)
      end

      it 'returns AuroraPgDialect for China old format cluster endpoint' do
        service = build_service(:postgresql, host: 'my-cluster.cluster-xyz.cn-northwest-1.rds.amazonaws.com.cn')
        expect(service.db_dialect).to be_a(AwsRubyDatabaseDriverWrapper::DbDialects::AuroraPgDialect)
      end
    end

    context 'Gov/ISO region endpoints' do
      it 'returns AuroraMysqlDialect for Gov cluster endpoint' do
        service = build_service(:mysql2, host: 'my-cluster.cluster-xyz.rds.us-gov-east-1.amazonaws.com')
        expect(service.db_dialect).to be_a(AwsRubyDatabaseDriverWrapper::DbDialects::AuroraMysqlDialect)
      end

      it 'returns AuroraMysqlDialect for ISO cluster endpoint' do
        service = build_service(:mysql2, host: 'my-cluster.cluster-xyz.rds.us-iso-east-1.c2s.ic.gov')
        expect(service.db_dialect).to be_a(AwsRubyDatabaseDriverWrapper::DbDialects::AuroraMysqlDialect)
      end
    end

    context 'state reset' do
      it 'sets can_update to false for non-updatable dialects' do
        service = build_service(:postgresql, host: 'my-global.global-xyz.global.rds.amazonaws.com')
        expect(service.dialect_final?).to be true
      end

      it 'sets can_update to true for updatable dialects' do
        service = build_service(:postgresql, host: 'my-cluster.cluster-xyz.us-east-2.rds.amazonaws.com')
        expect(service.dialect_final?).to be false
      end
    end

    context 'dialect_final?' do
      it 'is true before any connection when the dialect is not updatable' do
        service = build_service(:postgresql, host: 'my-global.global-xyz.global.rds.amazonaws.com')
        expect(service.dialect_final?).to be true
      end

      it 'is false before any connection when the dialect is still updatable' do
        service = build_service(:postgresql, host: 'my-cluster.cluster-xyz.us-east-2.rds.amazonaws.com')
        expect(service.dialect_final?).to be false
      end
    end
  end

  describe '#update_dialect' do
    context 'PostgreSQL driver' do
      let(:connection) { instance_double('PG::Connection') }
      let(:host) { 'my-cluster.cluster-xyz.us-east-2.rds.amazonaws.com' }
      let(:conn_service) { build_connection_service(host: host) }
      let(:global_patterns) { '?.xyz.us-east-2.rds.amazonaws.com,?.abc.us-west-2.rds.amazonaws.com' }
      let(:service) do
        build_service_with_container(:postgresql, host: host,
                                                  wrapper_props: { global_cluster_instance_host_patterns: global_patterns })
      end

      it 'returns current dialect without updating when not updatable' do
        global_service = build_service_with_container(
          :postgresql,
          host: 'my-global.global-xyz.global.rds.amazonaws.com',
          wrapper_props: { global_cluster_instance_host_patterns: '?.xyz.us-east-1.rds.amazonaws.com,?.abc.us-west-2.rds.amazonaws.com' }
        )
        original_dialect = global_service.db_dialect

        result = global_service.update_dialect(connection)
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

        result = service.update_dialect(connection)
        expect(result).to be_a(AwsRubyDatabaseDriverWrapper::DbDialects::GlobalPgDialect)
      end

      it 'caches the dialect after update' do
        allow(connection).to receive(:exec).and_raise(StandardError)

        service.update_dialect(connection)
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

        service.update_dialect(connection)

        host_url = conn_service.initial_host_info.url
        expect(described_class.known_endpoint_dialects.get(host)).to eq(AwsRubyDatabaseDriverWrapper::DialectCodes::GLOBAL_AURORA_PG)
        expect(described_class.known_endpoint_dialects.get(host_url)).to eq(AwsRubyDatabaseDriverWrapper::DialectCodes::GLOBAL_AURORA_PG)
      end

      it 'sets can_update to false after update completes without match' do
        allow(connection).to receive(:exec).and_raise(StandardError)

        service.update_dialect(connection)
        expect(service.dialect_final?).to be true
      end

      it 'keeps current dialect when no candidate matches but dialect is not UNKNOWN' do
        allow(connection).to receive(:exec).and_raise(StandardError)

        result = service.update_dialect(connection)
        expect(result).to be_a(AwsRubyDatabaseDriverWrapper::DbDialects::AuroraPgDialect)
      end
    end

    context 'MySQL driver' do
      let(:connection) { instance_double('Mysql2::Client', closed?: false) }
      let(:host) { 'my-cluster.cluster-xyz.us-east-2.rds.amazonaws.com' }
      let(:global_patterns) { '?.xyz.us-east-2.rds.amazonaws.com,?.abc.us-west-2.rds.amazonaws.com' }
      let(:conn_service) { build_connection_service(host: host) }
      let(:service) do
        build_service_with_container(:mysql2, host: host,
                                              wrapper_props: { global_cluster_instance_host_patterns: global_patterns })
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

        result = service.update_dialect(connection)
        expect(result).to be_a(AwsRubyDatabaseDriverWrapper::DbDialects::GlobalMysqlDialect)
      end

      it 'keeps AuroraMysqlDialect when no candidate matches' do
        allow(connection).to receive(:query).and_raise(StandardError)

        result = service.update_dialect(connection)
        expect(result).to be_a(AwsRubyDatabaseDriverWrapper::DbDialects::AuroraMysqlDialect)
      end

      it 'caches dialect for host after no candidate matches' do
        allow(connection).to receive(:query).and_raise(StandardError)

        service.update_dialect(connection)
        expect(described_class.known_endpoint_dialects.get(host)).to eq(AwsRubyDatabaseDriverWrapper::DialectCodes::AURORA_MYSQL)
      end
    end
  end

  describe '#dialect_for_code' do
    subject(:service) { build_service(:postgresql) }

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
      subject(:service) { build_service(:postgresql) }

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
      subject(:service) { build_service(:mysql2) }

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
      subject(:service) { build_service(:postgresql) }

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
      subject(:service) { build_service(:mysql2) }

      it 'returns true for access denied' do
        error = Mysql2::Error.allocate
        allow(error).to receive(:sql_state).and_return('28000')
        expect(service.login_error?(error)).to be true
      end
    end
  end

  describe '#read_only_error?' do
    context 'PostgreSQL' do
      subject(:service) { build_service(:postgresql) }

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
      subject(:service) { build_service(:mysql2) }

      it 'returns true for read-only error code 1290' do
        error = Mysql2::Error.allocate
        allow(error).to receive(:sql_state).and_return('HY000')
        allow(error).to receive(:error_number).and_return(1290)
        expect(service.read_only_error?(error)).to be true
      end
    end
  end
end
