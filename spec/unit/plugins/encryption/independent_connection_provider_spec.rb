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

require_relative '../../../spec_helper'
require 'aws_ruby_database_driver_wrapper/host/host_info'
require 'aws_ruby_database_driver_wrapper/plugins/kms_encryption/independent_connection_provider'
require 'aws_ruby_database_driver_wrapper/services/service_container'

RSpec.describe AwsRubyDatabaseDriverWrapper::Plugins::Encryption::IndependentConnectionProvider do
  let(:encryption) { AwsRubyDatabaseDriverWrapper::Plugins::Encryption }
  let(:services) { AwsRubyDatabaseDriverWrapper::Services }
  let(:host_info) { AwsRubyDatabaseDriverWrapper::Host::HostInfo.new(host: 'db.example.com', port: 5432) }
  let(:driver_props) { { host: 'db.example.com', dbname: 'app' } }
  let(:wrapper_props) { Concurrent::Map.new }
  let(:connection) { double('Connection') }
  let(:driver_dialect) { instance_double(AwsRubyDatabaseDriverWrapper::DriverDialects::PgDriverDialect) }
  let(:plugin_manager) { instance_double(services::PluginManager) }
  let(:connection_service) do
    instance_double(services::ConnectionService, current_host_info: host_info, driver_props: driver_props,
                                                 wrapper_props: wrapper_props)
  end
  let(:service_container) do
    instance_double(services::ServiceContainer,
                    connection_service: connection_service,
                    plugin_manager: plugin_manager,
                    dialect_service: instance_double(services::DialectService, driver_dialect: driver_dialect))
  end
  subject(:provider) { described_class.new(service_container) }

  before do
    allow(plugin_manager).to receive(:internal_connect).and_return(connection)
    allow(driver_dialect).to receive(:close_connection)
    allow(driver_dialect).to receive(:closed?).and_return(false)
  end

  it 'needs a service container to connect through' do
    expect { described_class.new(nil) }.to raise_error(ArgumentError, /service_container is required/)
  end

  describe '#open_connection' do
    # Going through the connect pipeline is what makes the metadata connection pick up IAM
    # authentication, Secrets Manager credentials, and the current writer host.
    it 'opens the connection through the internal connect pipeline' do
      expect(provider.open_connection).to be(connection)
      expect(plugin_manager).to have_received(:internal_connect).with(host_info, driver_props, wrapper_props, false)
    end

    # The pipeline is free to modify the properties it is given, and those belong to the
    # application's connection.
    it 'hands the pipeline a copy of the driver properties' do
      provider.open_connection
      expect(plugin_manager).to have_received(:internal_connect) do |_, props|
        expect(props).to eq(driver_props)
        expect(props).not_to be(driver_props)
      end
    end

    it 'reports a pipeline that returned nothing as a failure' do
      allow(plugin_manager).to receive(:internal_connect).and_return(nil)

      expect { provider.open_connection('GET_KEY_METADATA') }
        .to raise_error(AwsRubyDatabaseDriverWrapper::Errors::IndependentConnectionError,
                        /The connect pipeline returned no connection/) do |error|
        expect(error.connection_attempt).to eq('GET_KEY_METADATA')
        expect(error.attempted_parameters).to eq('db.example.com:5432/')
      end
    end

    it 'reports a refused connection, naming the operation that wanted it' do
      allow(plugin_manager).to receive(:internal_connect).and_raise(Errno::ECONNREFUSED)

      expect { provider.open_connection('METADATA_QUERY') }
        .to raise_error(AwsRubyDatabaseDriverWrapper::Errors::IndependentConnectionError) do |error|
          expect(error.connection_attempt).to eq('METADATA_QUERY')
          expect(error.failure_reason).to eq('Errno::ECONNREFUSED')
        end
    end
  end

  describe '#with_connection' do
    it 'yields the connection and returns what the block returned' do
      yielded = nil
      result = provider.with_connection(operation: 'GET_METADATA') do |conn|
        yielded = conn
        :rows
      end

      expect(yielded).to be(connection)
      expect(result).to eq(:rows)
    end

    # A metadata connection is opened per statement, so leaking one would leak a connection per
    # query the application makes.
    it 'closes the connection afterwards' do
      provider.with_connection { |_| :rows }
      expect(driver_dialect).to have_received(:close_connection).with(connection)
    end

    it 'closes the connection even when the block raised' do
      expect { provider.with_connection { raise 'relation does not exist' } }.to raise_error('relation does not exist')
      expect(driver_dialect).to have_received(:close_connection).with(connection)
    end

    # The statement has already run at this point, so a failure to close is not worth failing over.
    it 'swallows a failure to close' do
      allow(driver_dialect).to receive(:close_connection).and_raise(StandardError, 'connection already gone')
      expect(provider.with_connection { :rows }).to eq(:rows)
    end

    it 'does not run the block when the connection could not be opened' do
      allow(plugin_manager).to receive(:internal_connect).and_raise(Errno::ECONNREFUSED)
      ran = false

      expect { provider.with_connection { ran = true } }
        .to raise_error(AwsRubyDatabaseDriverWrapper::Errors::IndependentConnectionError)
      expect(ran).to be(false)
    end
  end

  describe '#validate_connection' do
    it 'is true when a usable connection can be opened' do
      expect(provider.validate_connection).to be(true)
      expect(driver_dialect).to have_received(:close_connection).with(connection)
    end

    it 'is false when the connection opens closed' do
      allow(driver_dialect).to receive(:closed?).and_return(true)
      expect(provider.validate_connection).to be(false)
    end

    it 'is false when no connection can be opened' do
      allow(plugin_manager).to receive(:internal_connect).and_raise(Errno::ECONNREFUSED)
      expect(provider.validate_connection).to be(false)
    end
  end

  describe 'the connection counters' do
    it 'start at zero' do
      expect(provider.request_count).to eq(0)
      expect(provider.successful_connection_count).to eq(0)
      expect(provider.failed_connection_count).to eq(0)
      expect(provider.last_successful_connection_time).to be_nil
      expect(provider.last_failed_connection_time).to be_nil
    end

    it 'count every request and every success' do
      2.times { provider.open_connection }

      expect(provider.request_count).to eq(2)
      expect(provider.successful_connection_count).to eq(2)
      expect(provider.last_successful_connection_time).to be_a(Float)
    end

    it 'count a failure' do
      allow(plugin_manager).to receive(:internal_connect).and_raise(Errno::ECONNREFUSED)

      expect { provider.open_connection }.to raise_error(AwsRubyDatabaseDriverWrapper::Errors::IndependentConnectionError)
      expect(provider.request_count).to eq(1)
      expect(provider.failed_connection_count).to eq(1)
      expect(provider.last_failed_connection_time).to be_a(Float)
    end
  end

  describe '#connection_success_rate' do
    # Nothing has gone wrong yet when nothing has been tried.
    it 'is one before any connection was attempted' do
      expect(provider.connection_success_rate).to eq(1.0)
    end

    it 'is the share of attempts that succeeded' do
      provider.open_connection
      allow(plugin_manager).to receive(:internal_connect).and_raise(Errno::ECONNREFUSED)
      expect { provider.open_connection }.to raise_error(AwsRubyDatabaseDriverWrapper::Errors::IndependentConnectionError)

      expect(provider.connection_success_rate).to eq(0.5)
    end
  end

  describe '#healthy?' do
    def fail_connections(count)
      allow(plugin_manager).to receive(:internal_connect).and_raise(Errno::ECONNREFUSED)
      count.times do
        expect { provider.open_connection }
          .to raise_error(AwsRubyDatabaseDriverWrapper::Errors::IndependentConnectionError)
      end
      allow(plugin_manager).to receive(:internal_connect).and_return(connection)
    end

    it 'is true before any connection was attempted' do
      expect(provider).to be_healthy
    end

    it 'is true while most connections succeed' do
      8.times { provider.open_connection }
      fail_connections(2)

      expect(provider).to be_healthy
    end

    it 'is false while most connections fail' do
      provider.open_connection
      fail_connections(4)

      expect(provider).not_to be_healthy
    end

    # A bad patch in the past should not keep the connection marked unhealthy forever.
    it 'is true again once the last failure is old enough' do
      fail_connections(1)
      old = provider.last_failed_connection_time - described_class::FAILURE_MEMORY_SEC - 1
      provider.instance_variable_set(:@last_failed_connection_time, old)

      expect(provider).to be_healthy
    end
  end

  describe '#health_status' do
    it 'summarizes the counters' do
      provider.open_connection

      expect(provider.health_status).to include('healthy=true', 'requests=1', 'successful=1', 'failed=0',
                                                'success_rate=100.00%', 'last_success=')
    end

    it 'reports how long ago the last failure was' do
      allow(plugin_manager).to receive(:internal_connect).and_raise(Errno::ECONNREFUSED)
      expect { provider.open_connection }.to raise_error(AwsRubyDatabaseDriverWrapper::Errors::IndependentConnectionError)

      expect(provider.health_status).to include('failed=1', 'success_rate=0.00%', 'last_failure=')
    end
  end

  describe '#log_health_status' do
    it 'logs a healthy provider at info level' do
      expect(provider.send(:logger)).to receive(:info).with(/Independent connection status: healthy=true/)
      provider.log_health_status
    end

    it 'logs an unhealthy provider at warn level' do
      allow(plugin_manager).to receive(:internal_connect).and_raise(Errno::ECONNREFUSED)
      allow(provider.send(:logger)).to receive(:debug)
      expect { provider.open_connection }.to raise_error(AwsRubyDatabaseDriverWrapper::Errors::IndependentConnectionError)

      expect(provider.send(:logger)).to receive(:warn).with(/healthy=false/)
      provider.log_health_status
    end

    it 'records the health check in the audit trail' do
      audit_logger = instance_double(encryption::AuditLogger)
      provider = described_class.new(service_container, audit_logger: audit_logger)
      allow(audit_logger).to receive(:log_connection_health_check)
      allow(audit_logger).to receive(:log_independent_connection_creation)
      allow(provider.send(:logger)).to receive(:info)

      provider.open_connection
      provider.log_health_status

      expect(audit_logger).to have_received(:log_connection_health_check)
        .with(connection_type: 'INDEPENDENT_CONNECTION', healthy: true, success_count: 1, failure_count: 0,
              success_rate: 1.0)
    end
  end

  describe 'the audit trail' do
    let(:audit_logger) { instance_double(encryption::AuditLogger) }
    subject(:provider) { described_class.new(service_container, audit_logger: audit_logger) }

    before { allow(audit_logger).to receive(:log_independent_connection_creation) }

    it 'records a connection that was opened' do
      provider.open_connection

      expect(audit_logger).to have_received(:log_independent_connection_creation)
        .with(target: 'db.example.com:5432/', success: true)
    end

    it 'records a connection that could not be opened' do
      allow(plugin_manager).to receive(:internal_connect).and_raise(Errno::ECONNREFUSED, 'db.example.com')
      allow(provider.send(:logger)).to receive(:debug)

      expect { provider.open_connection }.to raise_error(AwsRubyDatabaseDriverWrapper::Errors::IndependentConnectionError)
      expect(audit_logger).to have_received(:log_independent_connection_creation)
        .with(hash_including(target: 'db.example.com:5432/', success: false))
    end

    it 'logs the failure with the operation that wanted the connection' do
      allow(plugin_manager).to receive(:internal_connect).and_raise(Errno::ECONNREFUSED)

      expect(provider.send(:logger)).to receive(:debug)
        .with(/Independent connection creation failed.*\[Context: operation=STORE_KEY_METADATA\]/)
      expect { provider.open_connection('STORE_KEY_METADATA') }
        .to raise_error(AwsRubyDatabaseDriverWrapper::Errors::IndependentConnectionError)
    end
  end
end
