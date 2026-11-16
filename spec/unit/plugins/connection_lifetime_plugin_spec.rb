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
require 'aws_advanced_ruby_driver_wrapper/plugins/connection_lifetime_plugin'
require 'aws_advanced_ruby_driver_wrapper/driver_dialects/pg_driver_dialect'
require 'aws_advanced_ruby_driver_wrapper/host/host_info'
require 'aws_advanced_ruby_driver_wrapper/errors'
require 'aws_advanced_ruby_driver_wrapper/ruby_method'

RSpec.describe AwsAdvancedRubyDriverWrapper::Plugins::ConnectionLifetimePlugin do
  let(:errors) { AwsAdvancedRubyDriverWrapper::Errors }
  let(:ruby_method) { AwsAdvancedRubyDriverWrapper::RubyMethod }
  let(:query) { ruby_method::CONNECTION_EXEC.name }

  let(:original_host) { AwsAdvancedRubyDriverWrapper::Host::HostInfo.new(host: 'mydb.cluster-xyz.us-east-1.rds.amazonaws.com', port: 5432) }
  let(:instance_host) { AwsAdvancedRubyDriverWrapper::Host::HostInfo.new(host: 'instance-1.xyz.us-east-1.rds.amazonaws.com', port: 5432) }
  let(:driver_props) { { user: 'user' } }

  # A driver connection that reports whether it has been closed.
  let(:connection_class) do
    Class.new do
      attr_reader :name

      def initialize(name)
        @name = name
        @closed = false
      end

      def close
        @closed = true
      end

      def closed?
        @closed
      end

      # Every connection compares equal, so that only identity can tell them apart.
      def ==(_other)
        true
      end
      alias_method :eql?, :==

      def hash
        0
      end
    end
  end

  let(:first_connection) { connection_class.new('first') }
  let(:second_connection) { connection_class.new('second') }

  # Stands in for ConnectionService: update_current_connection closes the connection it replaces.
  let(:connection_service_class) do
    Class.new do
      attr_reader :current_connection, :current_host_info, :driver_props

      def initialize(driver_props)
        @driver_props = driver_props
      end

      def update_current_connection(connection, host_info)
        previous = @current_connection
        previous.close unless previous.nil? || previous.equal?(connection)
        @current_connection = connection
        @current_host_info = host_info
      end
    end
  end

  let(:connection_service) { connection_service_class.new(driver_props) }
  let(:session_state_service) { double('SessionStateService', in_transaction?: false) }
  let(:driver_dialect) do
    double('DriverDialect', network_bound_methods: AwsAdvancedRubyDriverWrapper::DriverDialects::PgDriverDialect::NETWORK_BOUND_METHODS)
  end
  let(:dialect_service) { double('DialectService', driver_dialect:) }
  let(:plugin_manager) { double('PluginManager') }
  let(:service_container) do
    double('ServiceContainer',
           connection_service:,
           session_state_service:,
           dialect_service:,
           plugin_manager:)
  end

  let(:now) { [100.0] }
  let(:clock) { -> { now[0] } }
  let(:props) { { connection_lifetime_sec: 10 } }

  def build_plugin(plugin_props = props)
    described_class.new(service_container, plugin_props, clock:)
  end

  # Runs the plugin's connect the way PluginManager does, with the driver connect installing the
  # connection it returns, as DefaultPlugin does.
  def open_connection(plugin, connection, host_info: original_host, is_initial_connection: true)
    plugin.connect(host_info, driver_props, is_initial_connection, lambda {
      connection_service.update_current_connection(connection, host_info)
      connection
    })
  end

  def advance(seconds)
    now[0] += seconds
  end

  def creation_times(plugin)
    plugin.instance_variable_get(:@creation_times)
  end

  before do
    allow(driver_dialect).to receive(:close_connection) { |conn| conn&.close }
    allow(driver_dialect).to receive(:closed?, &:closed?)
    allow(driver_dialect).to receive(:reported_in_transaction).and_return(nil)
  end

  describe 'configuration' do
    it 'accepts a positive number of seconds given as a number or a string' do
      expect { build_plugin(connection_lifetime_sec: 0.5) }.not_to raise_error
      expect { build_plugin(connection_lifetime_sec: '30') }.not_to raise_error
    end

    [nil, 0, -1, '0', 'abc', '', true, Float::INFINITY].each do |value|
      it "rejects connection_lifetime_sec #{value.inspect}" do
        expect { build_plugin(connection_lifetime_sec: value) }
          .to raise_error(errors::AwsError, /connection_lifetime_sec is required and must be a positive number/)
      end
    end

    it 'rejects a missing connection_lifetime_sec' do
      expect { build_plugin({}) }.to raise_error(errors::AwsError, /connection_lifetime_sec is required/)
    end

    it 'defaults connection_lifetime_action to reconnect' do
      expect(build_plugin.instance_variable_get(:@action)).to eq(:reconnect)
    end

    it 'reads connection_lifetime_action without regard to case or surrounding spaces' do
      expect(build_plugin(props.merge(connection_lifetime_action: ' CLOSE ')).instance_variable_get(:@action)).to eq(:close)
      expect(build_plugin(props.merge(connection_lifetime_action: 'Reconnect')).instance_variable_get(:@action)).to eq(:reconnect)
    end

    ['restart', '', nil].each do |value|
      it "rejects connection_lifetime_action #{value.inspect}" do
        expect { build_plugin(props.merge(connection_lifetime_action: value)) }
          .to raise_error(errors::AwsError, /connection_lifetime_action must be one of reconnect, close/)
      end
    end
  end

  describe '#subscribed_methods' do
    it 'subscribes to connect and the calls that reach the database, but not to the calls that release resources' do
      methods = build_plugin.subscribed_methods

      expect(methods).to include('connect', query, ruby_method::CONNECTION_EXEC_PARAMS.name, ruby_method::STATEMENT_EXECUTE.name,
                                 ruby_method::CONNECTION_RESET.name)
      expect(methods).not_to include(ruby_method::CONNECTION_CLOSE.name, ruby_method::STATEMENT_CLOSE.name,
                                     ruby_method::RESULT_FREE.name)
    end
  end

  describe 'close action' do
    let(:plugin) { build_plugin(props.merge(connection_lifetime_action: 'close')) }

    before { open_connection(plugin, first_connection) }

    it 'runs the call while the connection is younger than its lifetime' do
      advance(9.999)

      expect(plugin.execute(query, -> { :result })).to eq(:result)
      expect(first_connection).not_to be_closed
    end

    it 'closes the connection once its age equals the lifetime, without running the call' do
      advance(10)
      called = false

      expect { plugin.execute(query, -> { called = true }) }.to raise_error(errors::ConnectionLifetimeError) do |error|
        expect(error).to be_an_instance_of(errors::ConnectionLifetimeError)
        expect(error.connection_broken).to be true
        expect(error.needs_reconfiguration).to be false
      end
      expect(called).to be false
      expect(first_connection).to be_closed
      expect(creation_times(plugin)).to be_empty
    end

    it 'fails every later call without running it' do
      advance(10)
      expect { plugin.execute(query, -> {}) }.to raise_error(errors::ConnectionLifetimeError)

      called = false
      expect { plugin.execute(ruby_method::STATEMENT_EXECUTE.name, -> { called = true }) }
        .to raise_error(errors::ConnectionLifetimeError)
      expect(called).to be false
      expect(driver_dialect).to have_received(:close_connection).once
    end

    it 'fails later calls even when a new connection was made current' do
      advance(10)
      expect { plugin.execute(query, -> {}) }.to raise_error(errors::ConnectionLifetimeError)
      connection_service.update_current_connection(second_connection, original_host)

      expect { plugin.execute(query, -> {}) }.to raise_error(errors::ConnectionLifetimeError)
      expect(second_connection).not_to be_closed
    end

    # Active Record's PostgreSQL adapter recovers a broken connection by resetting it in place.
    it 'runs a reset on the closed connection and serves the reopened connection for a new lifetime' do
      advance(10)
      expect { plugin.execute(query, -> {}) }.to raise_error(errors::ConnectionLifetimeError)

      reset_ran = false
      plugin.execute(ruby_method::CONNECTION_RESET.name, lambda {
        reset_ran = true
        first_connection.instance_variable_set(:@closed, false)
      })
      expect(reset_ran).to be true

      advance(9.999)
      expect(plugin.execute(query, -> { :reopened })).to eq(:reopened)
      advance(0.001)
      expect { plugin.execute(query, -> {}) }.to raise_error(errors::ConnectionLifetimeError)
    end

    it 'serves the connection that failover swapped in while resetting the closed one' do
      advance(10)
      expect { plugin.execute(query, -> {}) }.to raise_error(errors::ConnectionLifetimeError)

      # The failover plugin finds the current connection closed, fails over, and raises.
      expect do
        plugin.execute(ruby_method::CONNECTION_RESET.name, lambda {
          connection_service.update_current_connection(second_connection, instance_host)
          raise errors::FailoverSuccessError
        })
      end.to raise_error(errors::FailoverSuccessError)

      expect(plugin.execute(query, -> { :failed_over })).to eq(:failed_over)
    end

    it 'keeps failing calls when a reset leaves the connection closed' do
      advance(10)
      expect { plugin.execute(query, -> {}) }.to raise_error(errors::ConnectionLifetimeError)

      expect { plugin.execute(ruby_method::CONNECTION_RESET.name, -> { raise StandardError, 'connection is closed' }) }
        .to raise_error(StandardError, 'connection is closed')
      called = false
      expect { plugin.execute(query, -> { called = true }) }.to raise_error(errors::ConnectionLifetimeError)
      expect(called).to be false
    end
  end

  describe 'transactions' do
    let(:plugin) { build_plugin }

    before { open_connection(plugin, first_connection) }

    it 'runs the call on the expired connection while a transaction is open' do
      allow(session_state_service).to receive(:in_transaction?).and_return(true)
      advance(15)

      expect(plugin.execute(query, -> { :in_transaction })).to eq(:in_transaction)
      expect(first_connection).not_to be_closed
    end

    it 'defers on the driver report of an open transaction when the tracked state has not caught up' do
      # The first statement inside a pg transaction block, before any call has returned to update the tracked state.
      allow(driver_dialect).to receive(:reported_in_transaction).with(first_connection).and_return(true)
      advance(15)

      expect(plugin.execute(query, -> { :in_transaction })).to eq(:in_transaction)
      expect(first_connection).not_to be_closed
    end

    it 'acts when the driver reports no transaction, whatever the tracked state says' do
      allow(driver_dialect).to receive(:reported_in_transaction).with(first_connection).and_return(false)
      allow(session_state_service).to receive(:in_transaction?).and_return(true)
      allow(plugin_manager).to receive(:connect).and_return(second_connection)
      advance(15)

      expect { plugin.execute(query, -> {}) }.to raise_error(errors::ConnectionLifetimeSuccessError)
    end

    it 'acts on the first call after the transaction ends, timing the connection from when it was opened' do
      allow(plugin_manager).to receive(:connect) do |host_info, *|
        connection_service.update_current_connection(second_connection, host_info)
        second_connection
      end
      allow(session_state_service).to receive(:in_transaction?).and_return(true)
      advance(15)
      plugin.execute(query, -> {})

      allow(session_state_service).to receive(:in_transaction?).and_return(false)

      expect { plugin.execute(query, -> {}) }.to raise_error(errors::ConnectionLifetimeSuccessError)
    end
  end

  describe 'reconnect action' do
    let(:plugin) { build_plugin }

    it 'reconnects to the host the application configured, not the instance the connection ended up on' do
      # A plugin further down the chain, such as initial_connection, opens the connection to an instance.
      plugin.connect(original_host, driver_props, true, lambda {
        open_connection(plugin, first_connection, host_info: instance_host)
      })
      expect(connection_service.current_host_info).to eq(instance_host)

      expect(plugin_manager).to receive(:connect)
        .with(original_host, driver_props, false, plugin_to_skip: plugin) do |host_info, *|
          connection_service.update_current_connection(second_connection, host_info)
          second_connection
        end
      advance(10)
      called = false

      expect { plugin.execute(query, -> { called = true }) }.to raise_error(errors::ConnectionLifetimeSuccessError) do |error|
        # The connection is usable, so a handler that discards connections on ConnectionLifetimeError must not see it.
        expect(error).not_to be_a(errors::ConnectionLifetimeError)
        expect(error.needs_reconfiguration).to be true
        expect(error.connection_broken).to be false
      end
      expect(called).to be false
      expect(connection_service.current_connection).to equal(second_connection)
      expect(connection_service.current_host_info).to eq(original_host)
      expect(first_connection).to be_closed
    end

    it 'installs the replacement when the connect did not make it the current connection' do
      open_connection(plugin, first_connection)
      allow(plugin_manager).to receive(:connect).and_return(second_connection)
      advance(10)

      expect { plugin.execute(query, -> {}) }.to raise_error(errors::ConnectionLifetimeSuccessError)
      expect(connection_service.current_connection).to equal(second_connection)
      expect(first_connection).to be_closed
    end

    it 'times the replacement from when it was installed' do
      open_connection(plugin, first_connection)
      allow(plugin_manager).to receive(:connect) do |host_info, *|
        advance(1)
        connection_service.update_current_connection(second_connection, host_info)
        second_connection
      end
      advance(10)
      expect { plugin.execute(query, -> {}) }.to raise_error(errors::ConnectionLifetimeSuccessError)

      advance(9.999)
      expect(plugin.execute(query, -> { :fresh })).to eq(:fresh)
      advance(0.001)
      expect { plugin.execute(query, -> {}) }.to raise_error(errors::ConnectionLifetimeSuccessError)
    end

    context 'when the replacement cannot be opened' do
      let(:connect_error) { StandardError.new('connection refused') }

      before do
        open_connection(plugin, first_connection)
        allow(plugin_manager).to receive(:connect).and_raise(connect_error)
        advance(10)
      end

      it 'raises ConnectionLifetimeFailedError with the connect error as its cause and keeps the old connection' do
        expect { plugin.execute(query, -> {}) }.to raise_error(errors::ConnectionLifetimeFailedError) do |error|
          expect(error.cause).to equal(connect_error)
          expect(error.connection_broken).to be true
        end
        expect(connection_service.current_connection).to equal(first_connection)
        expect(first_connection).not_to be_closed
      end

      it 'does not reset the timer, so the next call tries again' do
        expect { plugin.execute(query, -> {}) }.to raise_error(errors::ConnectionLifetimeFailedError)
        expect { plugin.execute(query, -> {}) }.to raise_error(errors::ConnectionLifetimeFailedError)

        expect(plugin_manager).to have_received(:connect).twice
      end
    end

    it 'starts a new lifetime when the expired connection is reset in place' do
      open_connection(plugin, first_connection)
      advance(10)
      expect(plugin_manager).not_to receive(:connect)

      expect(plugin.execute(ruby_method::CONNECTION_RESET.name, -> { :reset })).to eq(:reset)
      advance(9.999)
      expect(plugin.execute(query, -> { :ok })).to eq(:ok)
    end

    it 'raises ConnectionLifetimeFailedError when the connect returns no connection' do
      open_connection(plugin, first_connection)
      allow(plugin_manager).to receive(:connect).and_return(nil)
      advance(10)

      expect { plugin.execute(query, -> {}) }.to raise_error(errors::ConnectionLifetimeFailedError) do |error|
        expect(error.cause.message).to match(/did not return a connection/)
      end
      expect(connection_service.current_connection).to equal(first_connection)
    end

    it 'closes a replacement that could not be installed and keeps the old connection' do
      open_connection(plugin, first_connection)
      allow(plugin_manager).to receive(:connect).and_return(second_connection)
      allow(connection_service).to receive(:update_current_connection).and_raise(StandardError, 'install failed')
      advance(10)

      expect { plugin.execute(query, -> {}) }.to raise_error(errors::ConnectionLifetimeFailedError)
      expect(second_connection).to be_closed
      expect(first_connection).not_to be_closed
      expect(creation_times(plugin).keys).to contain_exactly(first_connection)

      # The plugin is not terminal: the old connection is still current and is tried again.
      allow(connection_service).to receive(:update_current_connection).and_call_original
      expect { plugin.execute(query, -> {}) }.to raise_error(errors::ConnectionLifetimeSuccessError)
    end

    it 'closes both connections and stops serving calls when the replacement was installed but the connect then failed' do
      open_connection(plugin, first_connection)
      # The connection init callback fails after the driver connection was made current.
      allow(plugin_manager).to receive(:connect) do |host_info, *|
        connection_service.update_current_connection(second_connection, host_info)
        raise StandardError, 'connection_init_func failed'
      end
      advance(10)

      expect { plugin.execute(query, -> {}) }.to raise_error(errors::ConnectionLifetimeFailedError)
      expect(first_connection).to be_closed
      expect(second_connection).to be_closed
      expect(creation_times(plugin)).to be_empty

      called = false
      expect { plugin.execute(query, -> { called = true }) }
        .to raise_error(errors::ConnectionLifetimeError) { |error| expect(error).to be_an_instance_of(errors::ConnectionLifetimeError) }
      expect(called).to be false
    end

    it 'raises ConnectionLifetimeFailedError when no initial connection was seen' do
      connection_service.update_current_connection(first_connection, original_host)
      expect(plugin_manager).not_to receive(:connect)
      plugin.execute(query, -> {})
      advance(10)

      expect { plugin.execute(query, -> {}) }.to raise_error(errors::ConnectionLifetimeFailedError) do |error|
        expect(error.cause.message).to match(/original host of the connection is unknown/)
      end
    end
  end

  describe 'tracking connections' do
    let(:plugin) { build_plugin }

    it 'keeps the original host from the first initial connect only' do
      open_connection(plugin, first_connection)
      # initial_connection opens its own initial connect to the instance it chose.
      open_connection(plugin, second_connection, host_info: instance_host)

      expect(plugin.instance_variable_get(:@original_host_info)).to equal(original_host)
    end

    it 'times a connection that another plugin swapped in from when it is first seen' do
      open_connection(plugin, first_connection)
      advance(8)
      # Failover swaps in a connection without going through this plugin's connect.
      connection_service.update_current_connection(second_connection, instance_host)

      expect(plugin.execute(query, -> { :ok })).to eq(:ok)
      advance(9.999)
      expect(plugin.execute(query, -> { :ok })).to eq(:ok)
      advance(0.001)
      allow(plugin_manager).to receive(:connect).and_return(connection_class.new('third'))
      expect { plugin.execute(query, -> {}) }.to raise_error(errors::ConnectionLifetimeSuccessError)
    end

    it 'times a connection opened through connect from when it was opened, even when it becomes current later' do
      open_connection(plugin, first_connection)
      # Failover opens a connection through the plugin chain, so this plugin records it.
      plugin.connect(instance_host, driver_props, false, -> { second_connection })
      advance(10)
      connection_service.update_current_connection(second_connection, instance_host)
      allow(plugin_manager).to receive(:connect).and_return(connection_class.new('third'))

      expect { plugin.execute(query, -> {}) }.to raise_error(errors::ConnectionLifetimeSuccessError)
    end

    it 'tells connections apart by identity, not by equality' do
      open_connection(plugin, first_connection)
      plugin.connect(instance_host, driver_props, false, -> { second_connection })

      expect(creation_times(plugin).size).to eq(2)
    end

    it 'drops the connections that were closed once the current connection changes' do
      open_connection(plugin, first_connection)
      plugin.execute(query, -> {})
      connection_service.update_current_connection(second_connection, instance_host)
      expect(creation_times(plugin).keys).to contain_exactly(first_connection)

      plugin.execute(query, -> {})

      expect(creation_times(plugin).keys).to contain_exactly(second_connection)
    end

    it 'keeps only the replacement after a reconnect' do
      open_connection(plugin, first_connection)
      third_connection = connection_class.new('third')
      allow(plugin_manager).to receive(:connect) do |host_info, *|
        connection_service.update_current_connection(third_connection, host_info)
        third_connection
      end
      advance(10)

      expect { plugin.execute(query, -> {}) }.to raise_error(errors::ConnectionLifetimeSuccessError)
      expect(creation_times(plugin).keys).to contain_exactly(third_connection)
    end

    it 'treats a connection that cannot report its state as closed' do
      open_connection(plugin, first_connection)
      allow(driver_dialect).to receive(:closed?).and_raise(StandardError, 'unknown state')
      connection_service.update_current_connection(second_connection, instance_host)

      plugin.execute(query, -> {})

      expect(creation_times(plugin).keys).to contain_exactly(second_connection)
    end

    it 'runs the call when there is no current connection' do
      expect(plugin.execute(query, -> { :no_connection })).to eq(:no_connection)
    end
  end
end
