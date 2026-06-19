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
require 'aws_ruby_database_driver_wrapper/plugins/blue_green/blue_green_plugin'
require 'aws_ruby_database_driver_wrapper/plugins/blue_green/status'
require 'aws_ruby_database_driver_wrapper/plugins/blue_green/phase'
require 'aws_ruby_database_driver_wrapper/plugins/blue_green/role'
require 'aws_ruby_database_driver_wrapper/plugins/blue_green/routing/base_routing'
require 'aws_ruby_database_driver_wrapper/plugins/blue_green/routing/suspend_connect_routing'
require 'aws_ruby_database_driver_wrapper/plugins/blue_green/routing/suspend_execute_routing'
require 'aws_ruby_database_driver_wrapper/services/service_container'
require 'aws_ruby_database_driver_wrapper/host/host_info'
require 'aws_ruby_database_driver_wrapper/ruby_method'
require 'concurrent'

RSpec.describe AwsRubyDatabaseDriverWrapper::Plugins::BlueGreen::BlueGreenPlugin do
  let(:bg)       { AwsRubyDatabaseDriverWrapper::Plugins::BlueGreen }
  let(:phase)    { bg::Phase }
  let(:role)     { bg::Role }
  let(:host_info_class) { AwsRubyDatabaseDriverWrapper::Host::HostInfo }

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
    AwsRubyDatabaseDriverWrapper::Services::ServiceContainer.new(
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
        result = plugin.execute(AwsRubyDatabaseDriverWrapper::RubyMethod::CONNECTION_CLOSE.name, pipeline)
        expect(result).to eq(:query_result)
      end

      it 'bypasses routing for statement.close' do
        result = plugin.execute(AwsRubyDatabaseDriverWrapper::RubyMethod::STATEMENT_CLOSE.name, pipeline)
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

  describe '#subscribed_methods' do
    it 'includes connect' do
      expect(plugin.subscribed_methods).to include('connect')
    end

    it 'includes network-bound methods from the driver dialect' do
      expect(plugin.subscribed_methods).to include('connection.query')
    end
  end
end
