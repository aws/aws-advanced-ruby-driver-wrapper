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
require 'aws_ruby_driver_wrapper/monitoring/global_cluster_topology_monitor'
require 'aws_ruby_driver_wrapper/host/host_info'
require 'aws_ruby_driver_wrapper/host/host_role'
require 'aws_ruby_driver_wrapper/utils/events/batching_event_publisher'
require 'aws_ruby_driver_wrapper/utils/storage/storage_service'

RSpec.describe AwsRubyDriverWrapper::Monitoring::GlobalClusterTopologyMonitor do
  let(:cluster_id) { 'global-test-cluster' }

  let(:us_east_template) do
    AwsRubyDriverWrapper::Host::HostInfo.new(
      host: '?.abc123.us-east-2.rds.amazonaws.com', port: 5432
    )
  end
  let(:us_west_template) do
    AwsRubyDriverWrapper::Host::HostInfo.new(
      host: '?.def456.us-west-2.rds.amazonaws.com', port: 5432
    )
  end
  let(:instance_templates_by_region) do
    { 'us-east-2' => us_east_template, 'us-west-2' => us_west_template }
  end

  let(:writer_host) do
    AwsRubyDriverWrapper::Host::HostInfo.new(
      host: 'writer-1.abc123.us-east-2.rds.amazonaws.com', port: 5432,
      role: AwsRubyDriverWrapper::Host::HostRole::WRITER, id: 'writer-1'
    )
  end
  let(:reader_east) do
    AwsRubyDriverWrapper::Host::HostInfo.new(
      host: 'reader-1.abc123.us-east-2.rds.amazonaws.com', port: 5432,
      role: AwsRubyDriverWrapper::Host::HostRole::READER, id: 'reader-1'
    )
  end
  let(:reader_west) do
    AwsRubyDriverWrapper::Host::HostInfo.new(
      host: 'reader-2.def456.us-west-2.rds.amazonaws.com', port: 5432,
      role: AwsRubyDriverWrapper::Host::HostRole::READER, id: 'reader-2'
    )
  end
  let(:global_topology) { [writer_host, reader_east, reader_west] }

  let(:mock_connection) { instance_double('Connection', close: nil) }

  let(:event_publisher) { AwsRubyDriverWrapper::Utils::Events::BatchingEventPublisher.new(message_interval_sec: 60) }
  let(:storage_service) { AwsRubyDriverWrapper::Utils::Storage::StorageService.new(event_publisher: event_publisher) }

  let(:db_dialect) { instance_double('DbDialect') }
  let(:driver_dialect) { instance_double('DriverDialect', close_connection: nil, apply_monitoring_defaults: nil, closed?: false) }
  let(:dialect_service) { instance_double('DialectService', db_dialect: db_dialect, driver_dialect: driver_dialect) }
  let(:initial_host_info) { AwsRubyDriverWrapper::Host::HostInfo.new(host: 'global.endpoint.rds.amazonaws.com', port: 5432) }
  let(:connection_config) do
    instance_double('ConnectionConfig', wrapper_props: {
                      cluster_topology_refresh_rate_ms: 100,
                      cluster_topology_high_refresh_rate_ms: 50,
                      cluster_topology_max_host_threads: 16
                    }, initial_host_info: initial_host_info)
  end
  let(:connection_service) do
    instance_double('ConnectionService', config: connection_config, wrapper_props: connection_config.wrapper_props,
                                         initial_host_info: initial_host_info)
  end
  let(:plugin_manager) { instance_double('PluginManager') }
  let(:service_container) do
    AwsRubyDriverWrapper::Services::ServiceContainer.new(
      event_publisher: event_publisher,
      storage_service: storage_service,
      dialect_service: dialect_service,
      connection_service: connection_service,
      plugin_manager: plugin_manager
    )
  end

  let(:topology_utils) { instance_double('GlobalAuroraTopologyUtils') }

  subject(:monitor) do
    described_class.new(
      service_container: service_container,
      cluster_id: cluster_id,
      instance_template: us_east_template,
      instance_templates_by_region: instance_templates_by_region,
      topology_utils: topology_utils,
      monitoring_driver_props: { host: 'localhost', port: 5432 },
      monitoring_wrapper_props: {}
    )
  end

  before do
    storage_service.register(:topology, ttl: 300)
    allow(topology_utils).to receive(:query_global_topology) { [writer_host, reader_east, reader_west] }
    allow(db_dialect).to receive(:host_role).and_return(AwsRubyDriverWrapper::Host::HostRole::WRITER)
    allow(plugin_manager).to receive(:internal_connect).and_return(mock_connection)
  end

  after do
    monitor.stop if monitor.state == :running
    event_publisher.release_resources
    storage_service.shutdown
  end

  describe '#query_topology override' do
    it 'calls query_global_topology with instance_templates_by_region' do
      monitor.instance_variable_get(:@monitoring_connection).set(mock_connection, close_old: false)
      monitor.instance_variable_set(:@verified_writer, true)

      monitor.start
      sleep(0.3)

      expect(topology_utils).to have_received(:query_global_topology).with(
        mock_connection, initial_host_info, instance_templates_by_region
      ).at_least(:once)
    end
  end

  describe 'multi-region topology caching' do
    it 'stores hosts from multiple regions in the topology cache' do
      monitor.start
      sleep(0.5)

      cached = storage_service.get(:topology, cluster_id, register_access: false)
      expect(cached).not_to be_nil
      expect(cached.size).to eq(3)

      hosts_by_region = cached.group_by { |h| h.host.match(/\.(us-[^.]+)\./)[1] }
      expect(hosts_by_region.keys).to contain_exactly('us-east-2', 'us-west-2')
    end
  end

  describe '#resolve_instance_template' do
    before do
      allow(topology_utils).to receive(:query_region).with('writer-1', mock_connection).and_return('us-east-2')
      allow(topology_utils).to receive(:query_region).with('reader-2', mock_connection).and_return('us-west-2')
      allow(topology_utils).to receive(:query_region).with('unknown', mock_connection).and_return(nil)
      allow(topology_utils).to receive(:query_region).with('bad-region', mock_connection).and_return('eu-west-1')
    end

    it 'returns the correct template for a known region' do
      result = monitor.send(:resolve_instance_template, 'writer-1', mock_connection)
      expect(result).to eq(us_east_template)
    end

    it 'returns template for a different region' do
      result = monitor.send(:resolve_instance_template, 'reader-2', mock_connection)
      expect(result).to eq(us_west_template)
    end

    it 'falls back to default template when region is nil' do
      result = monitor.send(:resolve_instance_template, 'unknown', mock_connection)
      expect(result).to eq(us_east_template)
    end

    it 'falls back to default template when region has no matching template' do
      result = monitor.send(:resolve_instance_template, 'bad-region', mock_connection)
      expect(result).to eq(us_east_template)
    end
  end
end
