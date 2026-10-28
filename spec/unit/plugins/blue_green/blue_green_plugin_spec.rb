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

# frozen_string_literal: true

require_relative '../../../spec_helper'
require 'aws_advanced_ruby_driver_wrapper/plugins/blue_green/blue_green_plugin'
require 'aws_advanced_ruby_driver_wrapper/plugins/blue_green/drop_blue_connections_marker'
require 'aws_advanced_ruby_driver_wrapper/plugins/blue_green/status'
require 'aws_advanced_ruby_driver_wrapper/plugins/blue_green/phase'
require 'aws_advanced_ruby_driver_wrapper/plugins/blue_green/role'
require 'aws_advanced_ruby_driver_wrapper/plugins/blue_green/routing/base_routing'
require 'aws_advanced_ruby_driver_wrapper/plugins/blue_green/routing/suspend_connect_routing'
require 'aws_advanced_ruby_driver_wrapper/plugins/blue_green/routing/suspend_execute_routing'
require 'aws_advanced_ruby_driver_wrapper/services/service_container'
require 'aws_advanced_ruby_driver_wrapper/host/host_info'
require 'aws_advanced_ruby_driver_wrapper/ruby_method'
require 'concurrent'

RSpec.describe AwsAdvancedRubyDriverWrapper::Plugins::BlueGreen::BlueGreenPlugin do
  let(:bg)       { AwsAdvancedRubyDriverWrapper::Plugins::BlueGreen }
  let(:phase)    { bg::Phase }
  let(:role)     { bg::Role }
  let(:host_info_class) { AwsAdvancedRubyDriverWrapper::Host::HostInfo }

  let(:bgd_id_val) { 'bgd-test' }
  let(:host_val)   { 'blue-instance.cluster-abc.us-east-1.rds.amazonaws.com' }

  let(:connection)      { double('connection') }
  let(:new_connection)  { double('new_connection') }
  let(:host_info)       { host_info_class.new(host: host_val, port: 3306) }
  let(:props)           { Concurrent::Map.new.tap { |p| p[:bgd_id] = bgd_id_val } }

  let(:storage_service) { double('storage_service', register: nil, get: nil, set: nil) }
  let(:driver_dialect)  { double('driver_dialect', network_bound_methods: Set['connection.query']) }
  let(:dialect_service) { double('dialect_service', driver_dialect: driver_dialect) }
  let(:host_list_provider) { double('host_list_provider', cluster_id: 'cluster-1') }
  let(:host_service) { double('host_service', host_list_provider: host_list_provider) }
  let(:connection_service) do
    double('connection_service',
           current_host_info: host_info,
           driver_props: Concurrent::Map.new,
           config: double('config', cluster_id: 'cluster-1'))
  end
  let(:plugin_manager) { double('plugin_manager') }

  let(:service_container) do
    AwsAdvancedRubyDriverWrapper::Services::ServiceContainer.new(
      connection_service, dialect_service, nil,
      host_service, plugin_manager, nil, storage_service, nil
    )
  end

  # Suppress StatusProvider construction in all tests
  before { allow_any_instance_of(described_class).to receive(:init_provider) }

  subject(:plugin) { described_class.new(service_container, props) }

  describe '#connect' do
    let(:pipeline) { -> { connection } }

    context 'when no BG status exists' do
      before { allow(storage_service).to receive(:get).and_return(nil) }

      it 'calls the pipeline and returns the connection' do
        expect(plugin.connect(host_info, props, true, pipeline)).to eq(connection)
      end
    end

    context 'when BG status exists but host has no role' do
      let(:status) { instance_double(bg::Status, current_phase: phase::CREATED, connect_routing: [], role: nil) }
      before { allow(storage_service).to receive(:get).and_return(status) }

      it 'calls the pipeline' do
        expect(plugin.connect(host_info, props, true, pipeline)).to eq(connection)
      end
    end

    context 'when a matching connect routing returns a new connection' do
      let(:routing) do
        double('routing',
               match?: true,
               apply: new_connection)
      end
      let(:status) do
        instance_double(bg::Status,
                        current_phase: phase::POST,
                        connect_routing: [routing],
                        role: role::SOURCE)
      end

      before { allow(storage_service).to receive(:get).and_return(status) }

      it 'returns the connection from the routing' do
        result = plugin.connect(host_info, props, true, pipeline)
        expect(result).to eq(new_connection)
      end

      it 'does not call the pipeline' do
        expect(pipeline).not_to receive(:call)
        plugin.connect(host_info, props, true, pipeline)
      end
    end

    context 'when routing returns nil (suspend/pass-through) then status clears' do
      let(:routing) { double('routing', match?: true, apply: nil) }
      let(:status)  { instance_double(bg::Status, current_phase: phase::IN_PROGRESS, connect_routing: [routing], role: role::SOURCE) }

      before do
        allow(storage_service).to receive(:get).and_return(status, nil)
      end

      it 'falls back to the pipeline when status disappears' do
        result = plugin.connect(host_info, props, true, pipeline)
        expect(result).to eq(connection)
      end
    end
  end

  describe '#execute' do
    let(:pipeline) { -> { :query_result } }

    context 'when no BG status exists' do
      before { allow(storage_service).to receive(:get).and_return(nil) }

      it 'calls the pipeline' do
        expect(plugin.execute('connection.query', pipeline)).to eq(:query_result)
      end
    end

    context 'when the method is a closing method' do
      before { allow(storage_service).to receive(:get).and_return(nil) }

      it 'bypasses routing for connection.close' do
        result = plugin.execute(AwsAdvancedRubyDriverWrapper::RubyMethod::CONNECTION_CLOSE.name, pipeline)
        expect(result).to eq(:query_result)
      end

      it 'bypasses routing for statement.close' do
        result = plugin.execute(AwsAdvancedRubyDriverWrapper::RubyMethod::STATEMENT_CLOSE.name, pipeline)
        expect(result).to eq(:query_result)
      end
    end

    context 'when host has no role in the status' do
      let(:status) { instance_double(bg::Status, current_phase: phase::IN_PROGRESS, execute_routing: [], role: nil) }
      before { allow(storage_service).to receive(:get).and_return(status) }

      it 'calls the pipeline' do
        expect(plugin.execute('connection.query', pipeline)).to eq(:query_result)
      end
    end

    context 'when a matching execute routing suspends then clears' do
      let(:routing) { double('routing', match?: true, apply: nil) }
      let(:status)  { instance_double(bg::Status, current_phase: phase::IN_PROGRESS, execute_routing: [routing], role: role::SOURCE) }

      before do
        allow(storage_service).to receive(:get).and_return(status, nil)
      end

      it 'calls the pipeline after routing passes through' do
        expect(plugin.execute('connection.query', pipeline)).to eq(:query_result)
      end
    end

    context 'when execute routing returns a non-nil result' do
      let(:routing) { double('routing', match?: true, apply: :routing_result) }
      let(:status)  { instance_double(bg::Status, current_phase: phase::IN_PROGRESS, execute_routing: [routing], role: role::SOURCE) }

      before { allow(storage_service).to receive(:get).and_return(status) }

      it 'returns the routing result without calling the pipeline' do
        expect(pipeline).not_to receive(:call)
        expect(plugin.execute('connection.query', pipeline)).to eq(:routing_result)
      end
    end
  end

  describe '#hold_time_ns' do
    before { allow(storage_service).to receive(:get).and_return(nil) }

    it 'returns 0 when no routing has occurred' do
      expect(plugin.hold_time_ns).to eq(0)
    end

    it 'returns a positive value while routing is in progress' do
      routing = double('routing', match?: true)
      status  = instance_double(bg::Status, current_phase: phase::IN_PROGRESS, connect_routing: [routing], role: role::SOURCE)

      allow(storage_service).to receive(:get).and_return(status)
      allow(routing).to receive(:apply) do
        # Simulate work during routing — check hold_time_ns mid-call
        expect(plugin.hold_time_ns).to be > 0
        new_connection
      end

      plugin.connect(host_info, props, true, -> { connection })
    end
  end

  describe 'dropping stale blue connections (#execute)' do
    let(:marker_class) { bg::DropBlueConnectionsMarker }
    let(:marker_key)   { described_class.drop_marker_key(bgd_id_val) }
    let(:bg_name)      { described_class::BLUE_GREEN_NAME }
    let(:marker_name)  { described_class::DROP_MARKER_NAME }

    # close_connection is needed on the driver dialect for invalidation.
    let(:driver_dialect) { double('driver_dialect', network_bound_methods: Set['connection.query'], close_connection: nil) }
    let(:connection_service) do
      double('connection_service',
             current_host_info: host_info,
             current_connection: connection,
             driver_props: Concurrent::Map.new,
             config: double('config', cluster_id: 'cluster-1'))
    end

    # A switchover time far above any real monotonic clock value, so a just-opened connection counts
    # as "opened before the switchover".
    let(:future_ns) { 1 << 62 }
    let(:marker) { marker_class.new(blue_hosts: [host_val.downcase], switchover_time_ns: future_ns, active: true) }

    before do
      allow(storage_service).to receive(:get).and_return(nil)
      allow(storage_service).to receive(:get).with(marker_name, marker_key, register_access: false).and_return(marker)
      # Record this connection's connect-time host and open time.
      plugin.connect(host_info, props, true, -> { connection })
    end

    context 'with an active marker for the connection host, opened before the switchover' do
      it 'closes the connection and continues down the pipeline' do
        expect(driver_dialect).to receive(:close_connection).with(connection)
        expect(plugin.execute('connection.query', -> { :query_result })).to eq(:query_result)
      end

      it 'does not invalidate the same connection twice for one marker' do
        plugin.execute('connection.query', -> { :query_result })
        expect(driver_dialect).not_to receive(:close_connection)
        expect(plugin.execute('connection.query', -> { :query_result })).to eq(:query_result)
      end

      # A close that raises is swallowed, but the marker must not be latched as handled — otherwise the
      # still-open connection would serve stale reads from retired blue for the rest of its life.
      it 'retries invalidation on the next use when the close fails' do
        expect(driver_dialect).to receive(:close_connection).with(connection).ordered.and_raise(StandardError, 'boom')
        expect(plugin.execute('connection.query', -> { :query_result })).to eq(:query_result)

        expect(driver_dialect).to receive(:close_connection).with(connection).ordered
        expect(plugin.execute('connection.query', -> { :query_result })).to eq(:query_result)
      end
    end

    context 'with a pending (not yet confirmed) marker' do
      let(:marker) { marker_class.new(blue_hosts: [host_val.downcase], switchover_time_ns: future_ns) }

      it 'does not invalidate the connection' do
        expect(driver_dialect).not_to receive(:close_connection)
        plugin.execute('connection.query', -> { :query_result })
      end

      # A pending check must not record the marker id, or activating the same marker later would never
      # invalidate this connection — it would stay open on retired blue.
      it 'still invalidates the connection once the same marker is activated' do
        plugin.execute('connection.query', -> { :query_result })

        allow(storage_service).to receive(:get).with(marker_name, marker_key, register_access: false).and_return(marker.activated)
        expect(driver_dialect).to receive(:close_connection).with(connection)
        plugin.execute('connection.query', -> { :query_result })
      end
    end

    # A connection opened through BG connect routing (route_connect) must also record its connect-time
    # host/open time, so it is invalidated on next use just like a plainly-connected one.
    context 'when the connection was opened through BG connect routing' do
      let(:connect_routing) { double('connect_routing', match?: true, apply: connection) }
      let(:connect_status) do
        instance_double(bg::Status, current_phase: phase::PREPARATION, connect_routing: [connect_routing], role: role::SOURCE)
      end

      it 'invalidates the routed connection on its next use after the switchover' do
        allow(storage_service).to receive(:get).with(bg_name, bgd_id_val).and_return(connect_status, nil)
        plugin.connect(host_info, props, true, -> { connection })

        expect(driver_dialect).to receive(:close_connection).with(connection)
        plugin.execute('connection.query', -> { :query_result })
      end
    end

    context 'with an active marker whose switchover predates the connection' do
      let(:marker) { marker_class.new(blue_hosts: [host_val.downcase], switchover_time_ns: 1, active: true) }

      it 'does not invalidate a connection opened after the switchover' do
        expect(driver_dialect).not_to receive(:close_connection)
        expect(plugin.execute('connection.query', -> { :query_result })).to eq(:query_result)
      end
    end

    context 'with an active marker that does not cover the connection host' do
      let(:marker) do
        marker_class.new(blue_hosts: ['green.cluster-abc.us-east-1.rds.amazonaws.com'], switchover_time_ns: future_ns, active: true)
      end

      it 'does not invalidate the connection' do
        expect(driver_dialect).not_to receive(:close_connection)
        plugin.execute('connection.query', -> { :query_result })
      end
    end

    # The provider stores the active marker before it writes the COMPLETED status, so a connection
    # that reads a COMPLETED status must still be invalidated via the marker rather than racing
    # past it on the COMPLETED early-return path.
    context 'with an active marker and a COMPLETED status' do
      let(:completed_status) { instance_double(bg::Status, current_phase: phase::COMPLETED) }

      it 'invalidates the stale connection instead of taking the COMPLETED early return' do
        allow(storage_service).to receive(:get).with(bg_name, bgd_id_val).and_return(completed_status)
        expect(driver_dialect).to receive(:close_connection).with(connection)
        plugin.execute('connection.query', -> { :query_result })
      end
    end

    context 'when bg_drop_blue_connections is disabled' do
      let(:props) do
        Concurrent::Map.new.tap do |p|
          p[:bgd_id] = bgd_id_val
          p[:bg_drop_blue_connections] = false
        end
      end

      it 'does not read the marker or invalidate the connection' do
        expect(driver_dialect).not_to receive(:close_connection)
        plugin.execute('connection.query', -> { :query_result })
      end
    end
  end

  describe '#subscribed_methods' do
    it 'includes connect' do
      expect(plugin.subscribed_methods).to include('connect')
    end

    it 'includes network-bound methods from the driver dialect' do
      expect(plugin.subscribed_methods).to include('connection.query')
    end
  end
end
