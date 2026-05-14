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

require_relative '../spec_helper'
require 'aws_ruby_database_driver_wrapper/plugins/default_plugin'
require 'aws_ruby_database_driver_wrapper/services/service_container'
require 'aws_ruby_database_driver_wrapper/services/connection_service'
require 'aws_ruby_database_driver_wrapper/services/dialect_service'
require 'aws_ruby_database_driver_wrapper/services/host_service'
require 'aws_ruby_database_driver_wrapper/host/host_info'
require 'aws_ruby_database_driver_wrapper/host/host_availability'
require 'aws_ruby_database_driver_wrapper/utils/connection_config'

RSpec.describe AwsRubyDatabaseDriverWrapper::Plugins::DefaultPlugin do
  let(:mock_connection) { double('Connection', host: 'test-instance.us-east-1.rds.example.com', port: '5432') }
  let(:driver_dialect) { double('DriverDialect') }
  let(:host_service) { instance_double(AwsRubyDatabaseDriverWrapper::Services::HostService, set_availability: nil) }
  let(:dialect_service) do
    instance_double(AwsRubyDatabaseDriverWrapper::Services::DialectService,
                    driver_dialect: driver_dialect,
                    update_dialect: nil)
  end
  let(:connection_service) do
    instance_double(AwsRubyDatabaseDriverWrapper::Services::ConnectionService,
                    pg?: false,
                    multi_host_url?: false,
                    initial_host_info: nil,
                    wrapper_props: wrapper_props)
  end
  let(:session_state_service) { nil }
  let(:service_container) do
    AwsRubyDatabaseDriverWrapper::Services::ServiceContainer.new(
      connection_service: connection_service,
      dialect_service: dialect_service,
      host_service: host_service,
      session_state_service: session_state_service
    )
  end
  let(:wrapper_props) { { plugins: '' } }
  let(:plugin) { described_class.new(service_container, **wrapper_props) }
  let(:host_info) do
    AwsRubyDatabaseDriverWrapper::Host::HostInfo.new(
      host: 'test-instance.abc123.us-east-1.rds.amazonaws.com', port: 5432
    )
  end
  let(:driver_props) { { host: 'test-instance.abc123.us-east-1.rds.amazonaws.com', port: 5432, dbname: 'testdb' } }

  describe '#connect' do
    before do
      allow(driver_dialect).to receive(:connect).and_return(mock_connection)
    end

    context 'successful connection' do
      it 'connects via the driver dialect' do
        conn = plugin.connect(host_info, driver_props, true, nil)
        expect(conn).to eq(mock_connection)
        expect(driver_dialect).to have_received(:connect).with(host_info, driver_props)
      end

      it 'marks host as available on success' do
        plugin.connect(host_info, driver_props, true, nil)
        expect(host_service).to have_received(:set_availability).with(
          host_info, AwsRubyDatabaseDriverWrapper::Host::HostAvailability::AVAILABLE
        )
      end

      it 'calls update_dialect on initial connection' do
        plugin.connect(host_info, driver_props, true, nil)
        expect(dialect_service).to have_received(:update_dialect).with(mock_connection)
      end

      it 'does not call update_dialect on non-initial connection' do
        plugin.connect(host_info, driver_props, false, nil)
        expect(dialect_service).not_to have_received(:update_dialect)
      end
    end

    context 'multi-host PG initial connection' do
      let(:connection_service) do
        instance_double(AwsRubyDatabaseDriverWrapper::Services::ConnectionService,
                        pg?: true,
                        multi_host_url?: true,
                        initial_host_info: nil,
                        'initial_host_info=': nil,
                        wrapper_props: wrapper_props)
      end

      it 'updates initial_host_info from the resolved connection' do
        plugin.connect(host_info, driver_props, true, nil)
        expect(connection_service).to have_received(:initial_host_info=) do |new_info|
          expect(new_info.host).to eq('test-instance.us-east-1.rds.example.com')
          expect(new_info.port).to eq(5432)
        end
      end

      it 'does not update initial_host_info on non-initial connection' do
        plugin.connect(host_info, driver_props, false, nil)
        expect(connection_service).not_to have_received(:initial_host_info=)
      end
    end

    context 'connection failure (non-DNS error)' do
      before do
        allow(driver_dialect).to receive(:connect).and_raise(StandardError, 'connection refused')
      end

      it 'propagates the error' do
        expect { plugin.connect(host_info, driver_props, true, nil) }
          .to raise_error(StandardError, 'connection refused')
      end

      it 'does not mark host as available' do
        begin
          plugin.connect(host_info, driver_props, true, nil)
        rescue StandardError
          nil
        end
        expect(host_service).not_to have_received(:set_availability)
      end
    end

    context 'green node replacement' do
      let(:green_host) { 'test-instance-green-abc123.xyz789.us-east-1.rds.amazonaws.com' }
      let(:green_host_info) do
        AwsRubyDatabaseDriverWrapper::Host::HostInfo.new(host: green_host, port: 5432)
      end
      let(:green_driver_props) { driver_props.merge(host: green_host) }

      context 'when enabled and green DNS does not resolve' do
        let(:wrapper_props) { { plugins: '', enable_green_node_replacement: true } }

        before do
          allow(Resolv).to receive(:getaddress).with(green_host).and_raise(Resolv::ResolvError)
          allow(driver_dialect).to receive(:connect) do |hi, _props|
            raise SocketError, 'getaddrinfo: Name or service not known' if hi.host == green_host

            mock_connection
          end
        end

        it 'falls back to the non-green host' do
          conn = plugin.connect(green_host_info, green_driver_props, true, nil)
          expect(conn).to eq(mock_connection)
        end

        it 'retries with the green prefix stripped from the host' do
          plugin.connect(green_host_info, green_driver_props, true, nil)
          expect(driver_dialect).to have_received(:connect).with(
            having_attributes(host: 'test-instance.xyz789.us-east-1.rds.amazonaws.com'),
            green_driver_props
          )
        end
      end

      context 'when enabled but green DNS resolves (host exists)' do
        let(:wrapper_props) { { plugins: '', enable_green_node_replacement: true } }

        before do
          allow(driver_dialect).to receive(:connect).and_raise(SocketError, 'getaddrinfo: Name or service not known')
          allow(Resolv).to receive(:getaddress).with(green_host).and_return('10.0.0.1')
        end

        it 're-raises the error since the host exists in DNS' do
          expect { plugin.connect(green_host_info, green_driver_props, true, nil) }
            .to raise_error(SocketError)
        end
      end

      context 'when disabled (default)' do
        let(:wrapper_props) { { plugins: '' } }

        before do
          allow(driver_dialect).to receive(:connect).and_raise(SocketError, 'getaddrinfo: Name or service not known')
        end

        it 'propagates the SocketError without fallback' do
          expect { plugin.connect(green_host_info, green_driver_props, true, nil) }
            .to raise_error(SocketError)
        end
      end

      context 'when host is not a green instance' do
        let(:wrapper_props) { { plugins: '', enable_green_node_replacement: true } }

        before do
          allow(driver_dialect).to receive(:connect).and_raise(SocketError, 'getaddrinfo: Name or service not known')
        end

        it 'does not attempt green node replacement for non-green hosts' do
          expect { plugin.connect(host_info, driver_props, true, nil) }
            .to raise_error(SocketError)
          expect(driver_dialect).to have_received(:connect).once
        end
      end
    end
  end

  describe '#execute' do
    it 'passes through to the target callable' do
      result = plugin.execute(nil, 'test_method', -> { 42 })
      expect(result).to eq(42)
    end

    it 'forwards arguments to the callable' do
      callable = ->(*args) { args.sum }
      result = plugin.execute(nil, 'connection.exec', callable, 1, 2, 3)
      expect(result).to eq(6)
    end

    it 'forwards blocks to the callable' do
      callable = ->(&block) { block.call(10) }
      result = plugin.execute(nil, 'connection.exec', callable) { |x| x * 2 }
      expect(result).to eq(20)
    end

    context 'with session state tracking' do
      let(:session_state_service) do
        double('SessionStateService',
               autocommit?: true,
               'in_transaction=': nil,
               'autocommit=': nil)
      end

      it 'marks in_transaction on BEGIN' do
        plugin.execute(nil, 'connection.exec', ->(*_) {}, 'BEGIN')
        expect(session_state_service).to have_received(:in_transaction=).with(true)
      end

      it 'clears in_transaction on COMMIT' do
        plugin.execute(nil, 'connection.exec', ->(*_) {}, 'COMMIT')
        expect(session_state_service).to have_received(:in_transaction=).with(false)
      end

      it 'clears in_transaction on ROLLBACK' do
        plugin.execute(nil, 'connection.exec', ->(*_) {}, 'ROLLBACK')
        expect(session_state_service).to have_received(:in_transaction=).with(false)
      end

      it 'tracks SET AUTOCOMMIT = TRUE' do
        plugin.execute(nil, 'connection.exec', ->(*_) {}, 'SET AUTOCOMMIT = TRUE')
        expect(session_state_service).to have_received(:autocommit=).with(true)
      end

      it 'tracks SET AUTOCOMMIT = FALSE' do
        plugin.execute(nil, 'connection.exec', ->(*_) {}, 'SET AUTOCOMMIT = FALSE')
        expect(session_state_service).to have_received(:autocommit=).with(false)
      end

      it 'does not track non-SQL methods' do
        plugin.execute(nil, 'connection.ping', -> { true })
        expect(session_state_service).not_to have_received(:in_transaction=)
        expect(session_state_service).not_to have_received(:autocommit=)
      end
    end

    context 'without session state service' do
      let(:session_state_service) { nil }

      it 'does not raise when session_state_service is nil' do
        result = plugin.execute(nil, 'connection.exec', ->(*_) { 'ok' }, 'BEGIN')
        expect(result).to eq('ok')
      end
    end
  end
end
