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
require 'concurrent'
require 'aws_advanced_ruby_driver_wrapper/plugins/initial_connection_strategy_plugin'
require 'aws_advanced_ruby_driver_wrapper/host/host_info'
require 'aws_advanced_ruby_driver_wrapper/host/host_role'
require 'aws_advanced_ruby_driver_wrapper/host/host_availability'
require 'aws_advanced_ruby_driver_wrapper/utils/rds_url_type'
require 'aws_advanced_ruby_driver_wrapper/errors'
require 'aws_advanced_ruby_driver_wrapper/services/plugin_manager'

RSpec.describe AwsAdvancedRubyDriverWrapper::Plugins::InitialConnectionStrategyPlugin do
  let(:host_info_class) { AwsAdvancedRubyDriverWrapper::Host::HostInfo }
  let(:host_role) { AwsAdvancedRubyDriverWrapper::Host::HostRole }
  let(:host_availability) { AwsAdvancedRubyDriverWrapper::Host::HostAvailability }
  let(:errors) { AwsAdvancedRubyDriverWrapper::Errors }

  let(:writer_cluster_host) { 'mydb.cluster-xyz.us-east-1.rds.amazonaws.com' }
  let(:reader_cluster_host) { 'mydb.cluster-ro-xyz.us-east-1.rds.amazonaws.com' }
  let(:global_writer_host) { 'mydb.global-xyz.global.rds.amazonaws.com' }
  let(:instance_host) { 'myinstance.xyz.us-east-1.rds.amazonaws.com' }
  let(:custom_cluster_host) { 'myalias.cluster-custom-xyz.us-east-1.rds.amazonaws.com' }

  let(:writer_host_info) do
    host_info_class.new(host: 'writer-instance.xyz.us-east-1.rds.amazonaws.com', role: host_role::WRITER)
  end
  let(:reader_host_info) do
    host_info_class.new(host: 'reader-instance.xyz.us-east-1.rds.amazonaws.com', role: host_role::READER)
  end
  let(:reader_host_info_west) do
    host_info_class.new(host: 'reader-instance.xyz.us-west-2.rds.amazonaws.com', role: host_role::READER)
  end

  let(:mock_connection) { double('Connection', close: nil) }
  let(:mock_db_dialect) { double('DbDialect') }
  let(:mock_driver_dialect) { double('DriverDialect', close_connection: nil) }
  let(:mock_dialect_service) do
    double('DialectService',
           db_dialect: mock_db_dialect,
           driver_dialect: mock_driver_dialect,
           dialect_final?: true,
           login_error?: false,
           network_error?: false,
           read_only_error?: false)
  end
  let(:mock_host_service) do
    double('HostService',
           all_hosts: [writer_host_info, reader_host_info],
           hosts: [writer_host_info, reader_host_info])
  end
  let(:mock_plugin_manager) { double('PluginManager') }
  let(:mock_service_container) do
    double('ServiceContainer',
           host_service: mock_host_service,
           dialect_service: mock_dialect_service,
           plugin_manager: mock_plugin_manager)
  end

  let(:pipeline_callable) { -> { mock_connection } }

  before do
    allow(mock_host_service).to receive(:force_refresh_host_list?)
    allow(mock_host_service).to receive(:set_availability)
    allow(mock_host_service).to receive(:select_host).and_return(reader_host_info)
    allow(mock_plugin_manager).to receive(:connect).and_return(mock_connection)
    allow(mock_db_dialect).to receive(:host_role).and_return(host_role::WRITER)
    allow(mock_db_dialect).to receive(:global?).and_return(false)
  end

  def build_plugin(props = {})
    wrapper_props = Concurrent::Map.new
    props.each { |k, v| wrapper_props[k] = v }
    described_class.new(mock_service_container, wrapper_props)
  end

  def make_host_info(host)
    host_info_class.new(host:)
  end

  describe 'registration' do
    it 'is registered in PluginManager with code initial_connection' do
      plugin_classes = AwsAdvancedRubyDriverWrapper::Services::PluginManager.plugin_classes
      expect(plugin_classes['initial_connection']).to eq(described_class)
    end

    it 'has weight 300' do
      plugin_weights = AwsAdvancedRubyDriverWrapper::Services::PluginManager.plugin_weights
      expect(plugin_weights[described_class]).to eq(300)
    end

    it 'runs before FailoverPlugin (weight 400)' do
      plugin_weights = AwsAdvancedRubyDriverWrapper::Services::PluginManager.plugin_weights
      expect(plugin_weights[described_class]).to be < plugin_weights[AwsAdvancedRubyDriverWrapper::Plugins::FailoverPlugin]
    end
  end

  describe '#subscribed_methods' do
    it 'subscribes only to connect' do
      plugin = build_plugin
      expect(plugin.subscribed_methods).to eq(Set['connect'])
    end
  end

  describe '#connect passthrough' do
    it 'passes through on non-initial connection' do
      plugin = build_plugin
      result = plugin.connect(make_host_info(writer_cluster_host), {}, false, pipeline_callable)
      expect(result).to eq(mock_connection)
    end

    it 'does not call connect on non-initial connection' do
      plugin = build_plugin
      expect(mock_plugin_manager).not_to receive(:connect)
      plugin.connect(make_host_info(writer_cluster_host), {}, false, pipeline_callable)
    end
  end

  describe '#connect with instance endpoint (no substitution)' do
    it 'connects via pipeline without substitution or verification' do
      plugin = build_plugin
      host = make_host_info(instance_host)

      result = plugin.connect(host, {}, true, pipeline_callable)
      expect(result).to eq(mock_connection)
    end

    it 'does not call connect for instance endpoints' do
      plugin = build_plugin
      expect(mock_plugin_manager).not_to receive(:connect)
      plugin.connect(make_host_info(instance_host), {}, true, pipeline_callable)
    end
  end

  describe '#connect with writer cluster endpoint' do
    it 'substitutes with writer instance and verifies writer role' do
      plugin = build_plugin
      allow(mock_db_dialect).to receive(:host_role).and_return(host_role::WRITER)

      expect(mock_plugin_manager).to receive(:connect)
        .with(writer_host_info, anything, true, plugin_to_skip: anything)
        .and_return(mock_connection)

      result = plugin.connect(make_host_info(writer_cluster_host), {}, true, pipeline_callable)
      expect(result).to eq(mock_connection)
    end

    it 'retries when connection has wrong role' do
      plugin = build_plugin(initial_connection_retry_timeout_ms: 100, initial_connection_retry_interval_ms: 10)

      call_count = 0
      allow(mock_plugin_manager).to receive(:connect).and_return(mock_connection)
      allow(mock_db_dialect).to receive(:host_role) do
        call_count += 1
        call_count >= 2 ? host_role::WRITER : host_role::READER
      end

      expect(mock_host_service).to receive(:force_refresh_host_list?).at_least(:once)

      result = plugin.connect(make_host_info(writer_cluster_host), {}, true, pipeline_callable)
      expect(result).to eq(mock_connection)
      expect(call_count).to be >= 2
    end
  end

  describe '#connect with reader cluster endpoint' do
    it 'substitutes with reader instance and verifies reader role' do
      plugin = build_plugin
      allow(mock_db_dialect).to receive(:host_role).and_return(host_role::READER)

      expect(mock_host_service).to receive(:select_host)
        .with(anything, host_role::READER, 'random')
        .and_return(reader_host_info)

      expect(mock_plugin_manager).to receive(:connect)
        .with(reader_host_info, anything, true, plugin_to_skip: anything)
        .and_return(mock_connection)

      result = plugin.connect(make_host_info(reader_cluster_host), {}, true, pipeline_callable)
      expect(result).to eq(mock_connection)
    end

    it 'accepts connection via original endpoint with warning when no readers exist in topology' do
      plugin = build_plugin
      allow(mock_host_service).to receive(:all_hosts).and_return([writer_host_info])
      allow(mock_host_service).to receive(:hosts).and_return([writer_host_info])
      allow(mock_host_service).to receive(:select_host).and_return(nil)
      allow(mock_db_dialect).to receive(:host_role).and_return(host_role::WRITER)

      # Falls through to pipeline_callable (original reader cluster endpoint) since no reader candidate found.
      # Aurora resolves the reader cluster endpoint to the writer when no readers exist.
      # Plugin detects role mismatch but accepts it since there are genuinely no readers.
      result = plugin.connect(make_host_info(reader_cluster_host), {}, true, pipeline_callable)
      expect(result).to eq(mock_connection)
    end

    it 'retries when reader cluster endpoint resolves to writer (stale DNS)' do
      plugin = build_plugin(initial_connection_retry_timeout_ms: 200, initial_connection_retry_interval_ms: 10)

      call_count = 0
      allow(mock_host_service).to receive(:select_host).and_return(reader_host_info)
      allow(mock_plugin_manager).to receive(:connect).and_return(mock_connection)
      allow(mock_db_dialect).to receive(:host_role) do
        call_count += 1
        call_count >= 2 ? host_role::READER : host_role::WRITER
      end

      expect(mock_host_service).to receive(:force_refresh_host_list?).at_least(:once)

      result = plugin.connect(make_host_info(reader_cluster_host), {}, true, pipeline_callable)
      expect(result).to eq(mock_connection)
      expect(call_count).to be >= 2
    end
  end

  describe '#connect with custom cluster endpoint' do
    it 'substitutes with any role using host selector strategy' do
      plugin = build_plugin(initial_connection_substitute_host: 'any')
      allow(mock_host_service).to receive(:select_host)
        .with(anything, nil, 'random')
        .and_return(writer_host_info)
      allow(mock_plugin_manager).to receive(:connect).and_return(mock_connection)

      result = plugin.connect(make_host_info(custom_cluster_host), {}, true, pipeline_callable)
      expect(result).to eq(mock_connection)
    end
  end

  describe '#connect with global writer endpoint' do
    it 'substitutes with writer instance and verifies writer role' do
      plugin = build_plugin
      allow(mock_db_dialect).to receive(:host_role).and_return(host_role::WRITER)

      expect(mock_plugin_manager).to receive(:connect)
        .with(writer_host_info, anything, true, plugin_to_skip: anything)
        .and_return(mock_connection)

      result = plugin.connect(make_host_info(global_writer_host), {}, true, pipeline_callable)
      expect(result).to eq(mock_connection)
    end
  end

  describe '#connect timeout' do
    it 'raises an error when retry timeout is exceeded' do
      plugin = build_plugin(initial_connection_retry_timeout_ms: 50, initial_connection_retry_interval_ms: 10)

      allow(mock_plugin_manager).to receive(:connect).and_return(mock_connection)
      allow(mock_db_dialect).to receive(:host_role).and_return(host_role::READER)

      expect(mock_driver_dialect).to receive(:close_connection).with(mock_connection).at_least(:once)

      expect do
        plugin.connect(make_host_info(writer_cluster_host), {}, true, pipeline_callable)
      end.to raise_error(errors::AwsError, /timed out/)
    end
  end

  describe '#connect error handling' do
    it 'raises immediately on login error' do
      plugin = build_plugin(initial_connection_retry_timeout_ms: 500)
      login_error = StandardError.new('login failed')

      allow(mock_plugin_manager).to receive(:connect).and_raise(login_error)
      allow(mock_dialect_service).to receive(:login_error?).with(login_error).and_return(true)

      expect do
        plugin.connect(make_host_info(writer_cluster_host), {}, true, pipeline_callable)
      end.to raise_error(login_error)
    end

    it 'retries on network error' do
      plugin = build_plugin(initial_connection_retry_timeout_ms: 200, initial_connection_retry_interval_ms: 10)
      network_error = StandardError.new('connection refused')

      call_count = 0
      allow(mock_plugin_manager).to receive(:connect) do
        call_count += 1
        raise network_error if call_count == 1

        mock_connection
      end
      allow(mock_dialect_service).to receive(:network_error?).with(network_error).and_return(true)
      allow(mock_db_dialect).to receive(:host_role).and_return(host_role::WRITER)

      result = plugin.connect(make_host_info(writer_cluster_host), {}, true, pipeline_callable)
      expect(result).to eq(mock_connection)
      expect(call_count).to be >= 2
    end

    it 'marks host unavailable on network error' do
      plugin = build_plugin(initial_connection_retry_timeout_ms: 200, initial_connection_retry_interval_ms: 10)
      network_error = StandardError.new('connection refused')

      call_count = 0
      allow(mock_plugin_manager).to receive(:connect) do
        call_count += 1
        raise network_error if call_count == 1

        mock_connection
      end
      allow(mock_dialect_service).to receive(:network_error?).with(network_error).and_return(true)
      allow(mock_db_dialect).to receive(:host_role).and_return(host_role::WRITER)

      expect(mock_host_service).to receive(:set_availability)
        .with(writer_host_info, host_availability::UNAVAILABLE)

      plugin.connect(make_host_info(writer_cluster_host), {}, true, pipeline_callable)
    end

    it 'waits the retry interval between network-error retries instead of spinning' do
      plugin = build_plugin(initial_connection_retry_timeout_ms: 200, initial_connection_retry_interval_ms: 10)
      network_error = StandardError.new('connection refused')

      call_count = 0
      allow(mock_plugin_manager).to receive(:connect) do
        call_count += 1
        raise network_error if call_count == 1

        mock_connection
      end
      allow(mock_dialect_service).to receive(:network_error?).with(network_error).and_return(true)
      allow(mock_db_dialect).to receive(:host_role).and_return(host_role::WRITER)

      # An unreachable candidate must back off by @retry_interval_sec (0.01s here) before looping,
      # otherwise the retry window is burned in a tight busy-loop.
      allow(plugin).to receive(:sleep)
      plugin.connect(make_host_info(writer_cluster_host), {}, true, pipeline_callable)
      expect(plugin).to have_received(:sleep).with(0.01).at_least(:once)
    end

    it 'retries on read-only error when wanting writer' do
      plugin = build_plugin(initial_connection_retry_timeout_ms: 200, initial_connection_retry_interval_ms: 10)
      readonly_error = StandardError.new('read only')

      call_count = 0
      allow(mock_plugin_manager).to receive(:connect) do
        call_count += 1
        raise readonly_error if call_count == 1

        mock_connection
      end
      allow(mock_dialect_service).to receive(:read_only_error?).with(readonly_error).and_return(true)
      allow(mock_db_dialect).to receive(:host_role).and_return(host_role::WRITER)

      result = plugin.connect(make_host_info(writer_cluster_host), {}, true, pipeline_callable)
      expect(result).to eq(mock_connection)
    end

    it 'raises on unknown error' do
      plugin = build_plugin(initial_connection_retry_timeout_ms: 500)
      unknown_error = StandardError.new('something unexpected')

      allow(mock_plugin_manager).to receive(:connect).and_raise(unknown_error)
      allow(mock_dialect_service).to receive(:login_error?).with(unknown_error).and_return(false)
      allow(mock_dialect_service).to receive(:network_error?).with(unknown_error).and_return(false)
      allow(mock_dialect_service).to receive(:read_only_error?).with(unknown_error).and_return(false)

      expect do
        plugin.connect(make_host_info(writer_cluster_host), {}, true, pipeline_callable)
      end.to raise_error(unknown_error)
    end
  end

  describe '#connect connection cleanup' do
    it 'closes connection on unexpected error' do
      plugin = build_plugin(initial_connection_retry_timeout_ms: 500)
      allow(mock_plugin_manager).to receive(:connect).and_return(mock_connection)
      allow(mock_db_dialect).to receive(:host_role).and_raise(RuntimeError, 'unexpected')

      expect(mock_driver_dialect).to receive(:close_connection).with(mock_connection)

      expect do
        plugin.connect(make_host_info(writer_cluster_host), {}, true, pipeline_callable)
      end.to raise_error(RuntimeError, 'unexpected')
    end
  end

  describe '#connect with wait_for_topology' do
    it 'waits for topology then connects to instance' do
      plugin = build_plugin(initial_connection_wait_for_topology_ms: 5000)

      # First call: topology empty, then after refresh it's available
      topology_call_count = 0
      allow(mock_host_service).to receive(:all_hosts) do
        topology_call_count += 1
        topology_call_count >= 2 ? [writer_host_info, reader_host_info] : []
      end
      allow(mock_host_service).to receive(:hosts).and_return([writer_host_info, reader_host_info])
      allow(mock_host_service).to receive(:force_refresh_host_list?)
      allow(mock_db_dialect).to receive(:host_role).and_return(host_role::WRITER)

      result = plugin.connect(make_host_info(writer_cluster_host), {}, true, pipeline_callable)
      expect(result).to eq(mock_connection)
    end
  end

  describe 'substitution strategy validation' do
    it 'raises when writer substitution is set for reader cluster' do
      plugin = build_plugin(initial_connection_substitute_host: 'writer')

      expect do
        plugin.connect(make_host_info(reader_cluster_host), {}, true, pipeline_callable)
      end.to raise_error(errors::AwsError, /invalid for reader/)
    end

    it 'raises when reader substitution is set for writer cluster' do
      plugin = build_plugin(initial_connection_substitute_host: 'reader')

      expect do
        plugin.connect(make_host_info(writer_cluster_host), {}, true, pipeline_callable)
      end.to raise_error(errors::AwsError, /invalid for writer/)
    end

    it 'raises when any substitution is set for non-custom cluster' do
      plugin = build_plugin(initial_connection_substitute_host: 'any')

      expect do
        plugin.connect(make_host_info(writer_cluster_host), {}, true, pipeline_callable)
      end.to raise_error(errors::AwsError, /only valid for custom/)
    end

    it 'raises when substitution is set for instance endpoint' do
      plugin = build_plugin(initial_connection_substitute_host: 'writer')

      expect do
        plugin.connect(make_host_info(instance_host), {}, true, pipeline_callable)
      end.to raise_error(errors::AwsError, /cannot be set when connecting to an instance/)
    end

    it 'raises at init for invalid substitution value' do
      expect do
        build_plugin(initial_connection_substitute_host: 'invalid')
      end.to raise_error(errors::AwsError, /Invalid initial_connection_substitute_host/)
    end

    it 'allows none substitution for any endpoint type' do
      plugin = build_plugin(initial_connection_substitute_host: 'none')

      result = plugin.connect(make_host_info(writer_cluster_host), {}, true, pipeline_callable)
      expect(result).to eq(mock_connection)
    end
  end

  describe 'verify role validation' do
    it 'raises when reader verification is set for writer cluster' do
      plugin = build_plugin(initial_connection_verify_role: 'reader')

      expect do
        plugin.connect(make_host_info(writer_cluster_host), {}, true, pipeline_callable)
      end.to raise_error(errors::AwsError, /invalid for writer/)
    end

    it 'raises when writer verification is set for reader cluster' do
      plugin = build_plugin(initial_connection_verify_role: 'writer')

      expect do
        plugin.connect(make_host_info(reader_cluster_host), {}, true, pipeline_callable)
      end.to raise_error(errors::AwsError, /invalid for reader/)
    end

    it 'raises when writer verification is set for custom cluster' do
      plugin = build_plugin(initial_connection_verify_role: 'writer')

      expect do
        plugin.connect(make_host_info(custom_cluster_host), {}, true, pipeline_callable)
      end.to raise_error(errors::AwsError, /invalid for reader or custom cluster/)
    end

    it 'raises at init for invalid verify role value' do
      expect do
        build_plugin(initial_connection_verify_role: 'invalid')
      end.to raise_error(errors::AwsError, /Invalid initial_connection_verify_role/)
    end

    it 'allows none verification to skip role check' do
      plugin = build_plugin(initial_connection_verify_role: 'none')
      allow(mock_plugin_manager).to receive(:connect).and_return(mock_connection)

      expect(mock_db_dialect).not_to receive(:host_role)

      result = plugin.connect(make_host_info(writer_cluster_host), {}, true, pipeline_callable)
      expect(result).to eq(mock_connection)
    end
  end

  describe 'inactive cluster writer endpoint' do
    let(:writer_in_different_region) do
      host_info_class.new(host: 'writer-instance.xyz.us-west-2.rds.amazonaws.com', role: host_role::WRITER)
    end

    before do
      allow(mock_host_service).to receive(:all_hosts).and_return([writer_in_different_region, reader_host_info])
      allow(mock_host_service).to receive(:hosts).and_return([writer_in_different_region, reader_host_info])
      # Inactive cluster detection only applies to a confirmed Global Aurora Database whose
      # cross-region topology shows the writer living in a different region than the endpoint.
      allow(mock_db_dialect).to receive(:global?).and_return(true)
    end

    it 'uses inactive_substitute_host setting when cluster is inactive' do
      plugin = build_plugin(initial_connection_inactive_substitute_host: 'writer')
      allow(mock_plugin_manager).to receive(:connect).and_return(mock_connection)
      allow(mock_db_dialect).to receive(:host_role).and_return(host_role::WRITER)

      expect(mock_plugin_manager).to receive(:connect)
        .with(writer_in_different_region, anything, true, plugin_to_skip: anything)
        .and_return(mock_connection)

      plugin.connect(make_host_info(writer_cluster_host), {}, true, pipeline_callable)
    end

    it 'does not substitute when inactive_substitute_host is none' do
      plugin = build_plugin(initial_connection_inactive_substitute_host: 'none')

      result = plugin.connect(make_host_info(writer_cluster_host), {}, true, pipeline_callable)
      expect(result).to eq(mock_connection)
    end

    it 'passes through without substitution or verification when no inactive props are set' do
      plugin = build_plugin

      # Neither cross-region writer substitution nor role verification should occur by default;
      # the inactive endpoint is passed through untouched.
      expect(mock_plugin_manager).not_to receive(:connect)
      expect(mock_db_dialect).not_to receive(:host_role)

      result = plugin.connect(make_host_info(writer_cluster_host), {}, true, pipeline_callable)
      expect(result).to eq(mock_connection)
    end

    it 'uses inactive_verify_role setting for verification' do
      plugin = build_plugin(initial_connection_inactive_verify_role: 'none')
      allow(mock_plugin_manager).to receive(:connect).and_return(mock_connection)

      expect(mock_db_dialect).not_to receive(:host_role)

      plugin.connect(make_host_info(writer_cluster_host), {}, true, pipeline_callable)
    end

    it 'raises at init when inactive_substitute_host is reader' do
      expect do
        build_plugin(initial_connection_inactive_substitute_host: 'reader')
      end.to raise_error(errors::AwsError, /initial_connection_inactive_substitute_host.*not valid.*'writer' or 'none'/)
    end

    it 'raises at init when inactive_verify_role is reader' do
      expect do
        build_plugin(initial_connection_inactive_verify_role: 'reader')
      end.to raise_error(errors::AwsError, /initial_connection_inactive_verify_role.*not valid.*'writer' or 'none'/)
    end
  end

  describe 'accessible_regions filtering' do
    let(:host_west) do
      host_info_class.new(host: 'writer-instance.xyz.us-west-2.rds.amazonaws.com', role: host_role::WRITER)
    end

    it 'filters candidate hosts by accessible regions' do
      plugin = build_plugin(accessible_regions: 'us-west-2')

      allow(mock_host_service).to receive(:all_hosts).and_return([writer_host_info, host_west])
      allow(mock_plugin_manager).to receive(:connect).and_return(mock_connection)
      allow(mock_db_dialect).to receive(:host_role).and_return(host_role::WRITER)

      # Should connect to us-west-2 writer since us-east-1 is filtered out
      expect(mock_plugin_manager).to receive(:connect)
        .with(host_west, anything, true, plugin_to_skip: anything)
        .and_return(mock_connection)

      plugin.connect(make_host_info(writer_cluster_host), {}, true, pipeline_callable)
    end
  end

  describe 'property defaults' do
    it 'uses default retry timeout of 30s' do
      plugin = build_plugin
      expect(plugin.instance_variable_get(:@retry_timeout_sec)).to eq(30.0)
    end

    it 'uses default retry interval of 1s' do
      plugin = build_plugin
      expect(plugin.instance_variable_get(:@retry_interval_sec)).to eq(1.0)
    end

    it 'uses default wait_for_topology of 0s' do
      plugin = build_plugin
      expect(plugin.instance_variable_get(:@wait_for_topology_sec)).to eq(0.0)
    end

    it 'uses default host selector strategy of random' do
      plugin = build_plugin
      expect(plugin.instance_variable_get(:@host_selector_strategy)).to eq('random')
    end

    it 'uses nil accessible_regions by default' do
      plugin = build_plugin
      expect(plugin.instance_variable_get(:@accessible_regions)).to be_nil
    end
  end
end
