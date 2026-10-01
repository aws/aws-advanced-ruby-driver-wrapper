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
require 'aws_advanced_ruby_driver_wrapper/plugins/default_plugin'
require 'aws_advanced_ruby_driver_wrapper/services/service_container'
require 'aws_advanced_ruby_driver_wrapper/services/connection_service'
require 'aws_advanced_ruby_driver_wrapper/services/dialect_service'
require 'aws_advanced_ruby_driver_wrapper/services/host_service'
require 'aws_advanced_ruby_driver_wrapper/host/host_info'
require 'aws_advanced_ruby_driver_wrapper/host/host_availability'
require 'aws_advanced_ruby_driver_wrapper/utils/connection_config'

RSpec.describe AwsAdvancedRubyDriverWrapper::Plugins::DefaultPlugin do
  let(:mock_connection) { double('Connection', host: 'test-instance.us-east-1.rds.example.com', port: '5432') }
  let(:driver_dialect) { double('DriverDialect') }
  let(:host_service) { instance_double(AwsAdvancedRubyDriverWrapper::Services::HostService, set_availability: nil, refresh_host_list: nil) }
  let(:db_dialect) { double('DbDialect', create_host_list_provider: nil) }
  let(:dialect_service) do
    instance_double(AwsAdvancedRubyDriverWrapper::Services::DialectService,
                    driver_dialect: driver_dialect,
                    update_dialect: nil,
                    db_dialect: db_dialect)
  end
  let(:connection_service) do
    instance_double(AwsAdvancedRubyDriverWrapper::Services::ConnectionService,
                    pg?: false,
                    multi_host_url?: false,
                    wrapper_props: wrapper_props,
                    update_current_connection: nil)
  end
  let(:session_state_service) { nil }
  let(:service_container) do
    AwsAdvancedRubyDriverWrapper::Services::ServiceContainer.new(
      connection_service: connection_service,
      dialect_service: dialect_service,
      host_service: host_service,
      session_state_service: session_state_service
    )
  end
  let(:wrapper_props) { { plugins: '' } }
  let(:plugin) { described_class.new(service_container, wrapper_props) }
  let(:host_info) do
    AwsAdvancedRubyDriverWrapper::Host::HostInfo.new(
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
          host_info, AwsAdvancedRubyDriverWrapper::Host::HostAvailability::AVAILABLE
        )
      end

      it 'calls update_dialect on initial connection' do
        plugin.connect(host_info, driver_props, true, nil)
        expect(dialect_service).to have_received(:update_dialect).with(mock_connection)
      end

      it 'calls update_current_connection with the new connection and host_info' do
        plugin.connect(host_info, driver_props, true, nil)
        expect(connection_service).to have_received(:update_current_connection).with(mock_connection, host_info)
      end

      it 'calls update_current_connection before update_dialect' do
        call_order = []
        allow(connection_service).to receive(:update_current_connection) { call_order << :update_current_connection }
        allow(dialect_service).to receive(:update_dialect) { call_order << :update_dialect }

        plugin.connect(host_info, driver_props, true, nil)

        expect(call_order).to eq(%i[update_current_connection update_dialect])
      end

      it 'does not call update_dialect on non-initial connection' do
        plugin.connect(host_info, driver_props, false, nil)
        expect(dialect_service).not_to have_received(:update_dialect)
      end
    end

    context 'multi-host PG initial connection' do
      let(:initial_host_info_obj) do
        AwsAdvancedRubyDriverWrapper::Host::HostInfo.new(
          host: 'host1,host2',
          port: ',5433'
        )
      end
      let(:mock_config) do
        instance_double(AwsAdvancedRubyDriverWrapper::Utils::ConnectionConfig,
                        initial_host_info: initial_host_info_obj,
                        original_host: 'host1,host2',
                        original_port: ',5433')
      end
      let(:connection_service) do
        instance_double(AwsAdvancedRubyDriverWrapper::Services::ConnectionService,
                        pg?: true,
                        multi_host_url?: true,
                        config: mock_config,
                        initial_host_info: initial_host_info_obj,
                        wrapper_props: wrapper_props,
                        update_current_connection: nil)
      end

      before do
        allow(mock_config).to receive(:initial_host_info=)
      end

      it 'updates initial_host_info from the resolved connection' do
        plugin.connect(host_info, driver_props, true, nil)
        expect(mock_config).to have_received(:initial_host_info=) do |new_info|
          expect(new_info.host).to eq('test-instance.us-east-1.rds.example.com')
          expect(new_info.port).to eq(5432)
        end
      end

      it 'connects using initial_host_info from the connection service' do
        plugin.connect(host_info, driver_props, true, nil)
        expect(driver_dialect).to have_received(:connect).with(initial_host_info_obj, driver_props)
      end

      it 'does not update initial_host_info on non-initial connection' do
        plugin.connect(host_info, driver_props, false, nil)
        expect(mock_config).not_to have_received(:initial_host_info=)
      end

      it 'passes host_info to the driver on non-initial connection' do
        plugin.connect(host_info, driver_props, false, nil)
        expect(driver_dialect).to have_received(:connect).with(host_info, driver_props)
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
  end

  describe '#execute' do
    it 'passes through to the target callable' do
      result = plugin.execute('test_method', -> { 42 })
      expect(result).to eq(42)
    end

    it 'forwards arguments to the callable' do
      callable = ->(*args) { args.sum }
      result = plugin.execute('connection.exec', callable, 1, 2, 3)
      expect(result).to eq(6)
    end

    it 'forwards blocks to the callable' do
      callable = ->(&block) { block.call(10) }
      result = plugin.execute('connection.exec', callable) { |x| x * 2 }
      expect(result).to eq(20)
    end

    context 'with session state tracking' do
      let(:session_state_service) do
        double('SessionStateService',
               autocommit?: true,
               update_transaction_state: nil)
      end

      before do
        allow(connection_service).to receive(:current_connection).and_return(mock_connection)
        allow(driver_dialect).to receive(:reported_in_transaction).and_return(nil)
      end

      it 'calls update_transaction_state on success' do
        plugin.execute('connection.exec', -> { 'ok' })
        expect(session_state_service).to have_received(:update_transaction_state)
      end
    end

    context 'without session state service' do
      let(:session_state_service) { nil }

      it 'does not raise when session_state_service is nil' do
        result = plugin.execute('connection.exec', ->(*_) { 'ok' }, 'BEGIN')
        expect(result).to eq('ok')
      end

      it 'propagates exceptions when session_state_service is nil' do
        expect do
          plugin.execute('connection.copy_data', -> { raise 'boom' })
        end.to raise_error(RuntimeError, 'boom')
      end
    end

    context 'when the callable raises' do
      let(:mock_conn) { double('Connection') }
      let(:session_state_service) do
        double('SessionStateService',
               autocommit?: true,
               update_transaction_state: nil)
      end

      before do
        allow(connection_service).to receive(:current_connection).and_return(mock_conn)
        allow(driver_dialect).to receive(:reported_in_transaction).and_return(nil)
      end

      it 're-raises the exception' do
        expect do
          plugin.execute('connection.copy_data', -> { raise 'copy failed' })
        end.to raise_error(RuntimeError, 'copy failed')
      end

      it 'calls update_transaction_state once even when the callable raises' do
        begin
          plugin.execute('connection.copy_data', -> { raise RuntimeError })
        rescue StandardError
          nil
        end
        expect(session_state_service).to have_received(:update_transaction_state).once
      end

      it 'calls update_transaction_state with the real method_name on the error path' do
        begin
          plugin.execute('connection.copy_data', -> { raise RuntimeError })
        rescue StandardError
          nil
        end
        expect(session_state_service).to have_received(:update_transaction_state)
          .with('connection.copy_data', [], true, driver_dialect, mock_conn, succeeded: false)
      end

      it 'skips state sync when current_connection is nil' do
        allow(connection_service).to receive(:current_connection).and_return(nil)
        expect do
          plugin.execute('connection.copy_data', -> { raise 'boom' })
        end.to raise_error(RuntimeError, 'boom')
        expect(session_state_service).not_to have_received(:update_transaction_state)
      end
    end
  end
end
