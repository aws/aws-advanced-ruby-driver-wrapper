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
require 'aws_ruby_database_driver_wrapper/host/rds_host_list_provider'
require 'aws_ruby_database_driver_wrapper/host/host_info'
require 'aws_ruby_database_driver_wrapper/host/host_role'
require 'aws_ruby_database_driver_wrapper/utils/events/batching_event_publisher'
require 'aws_ruby_database_driver_wrapper/utils/storage/storage_service'
require 'aws_ruby_database_driver_wrapper/services/service_container'
require 'aws_ruby_database_driver_wrapper/services/monitor_service'

RSpec.describe AwsRubyDatabaseDriverWrapper::Host::RdsHostListProvider do
  let(:initial_host_info) do
    AwsRubyDatabaseDriverWrapper::Host::HostInfo.new(
      host: 'my-cluster.cluster-abc123.us-east-2.rds.amazonaws.com',
      port: 5432
    )
  end
  let(:wrapper_props) { {} }
  let(:driver_props) { { user: 'admin', password: 'secret', dbname: 'test' } }
  let(:prefixed_props) { {} }
  let(:connection_config) do
    instance_double('ConnectionConfig',
                    wrapper_props: wrapper_props,
                    driver_props: driver_props,
                    prefixed_props: prefixed_props,
                    initial_host_info: initial_host_info)
  end
  let(:connection_service) do
    instance_double('ConnectionService', config: connection_config,
                                         wrapper_props: wrapper_props,
                                         driver_props: driver_props,
                                         prefixed_props: prefixed_props,
                                         initial_host_info: initial_host_info)
  end
  let(:driver_dialect) { instance_double('DriverDialect', connect: nil) }
  let(:db_dialect) { instance_double('DbDialect') }
  let(:dialect_service) do
    instance_double('DialectService', driver_dialect: driver_dialect, db_dialect: db_dialect, dialect_confirmed?: true)
  end
  let(:event_publisher) do
    AwsRubyDatabaseDriverWrapper::Utils::Events::BatchingEventPublisher.new(message_interval_sec: 60)
  end
  let(:storage_service) do
    AwsRubyDatabaseDriverWrapper::Utils::Storage::StorageService.new(event_publisher: event_publisher)
  end
  let(:monitor_service) do
    AwsRubyDatabaseDriverWrapper::Services::MonitorService.new(event_publisher: event_publisher)
  end
  let(:plugin_manager) { instance_double('PluginManager', internal_connect: nil) }
  let(:service_container) do
    AwsRubyDatabaseDriverWrapper::Services::ServiceContainer.new(
      event_publisher: event_publisher,
      storage_service: storage_service,
      dialect_service: dialect_service,
      connection_service: connection_service,
      monitor_service: monitor_service,
      plugin_manager: plugin_manager
    )
  end
  let(:topology_utils) { instance_double('TopologyUtils') }

  before do
    storage_service.register(:topology, ttl: 300)
  end

  after do
    event_publisher.release_resources
    storage_service.shutdown
    monitor_service.shutdown(grace_period: 2)
  end

  subject(:provider) do
    described_class.new(service_container: service_container, topology_utils: topology_utils)
  end

  describe '#initialize' do
    it 'derives cluster_id from wrapper_props' do
      expect(provider.cluster_id).to eq('1')
    end

    context 'with custom cluster_id' do
      let(:wrapper_props) { { cluster_id: 'my-cluster' } }

      it 'uses the custom cluster_id' do
        expect(provider.cluster_id).to eq('my-cluster')
      end
    end

    it 'auto-derives instance_template from initial_host_info' do
      expect(provider.instance_template.host).to eq('?.abc123.us-east-2.rds.amazonaws.com')
      expect(provider.instance_template.port).to eq(5432)
    end

    context 'with explicit cluster_instance_host_pattern' do
      let(:wrapper_props) { { cluster_instance_host_pattern: '?.custom-domain.com' } }

      it 'uses the provided pattern' do
        expect(provider.instance_template.host).to eq('?.custom-domain.com')
      end
    end

    it 'identifies rds_url_type' do
      expect(provider.rds_url_type).to eq(AwsRubyDatabaseDriverWrapper::Utils::RdsUrlType::RDS_WRITER_CLUSTER)
    end

    context 'with proxy host pattern' do
      let(:initial_host_info) do
        AwsRubyDatabaseDriverWrapper::Host::HostInfo.new(
          host: 'my-proxy.proxy-abc123.us-east-2.rds.amazonaws.com', port: 5432
        )
      end
      let(:wrapper_props) { { cluster_instance_host_pattern: '?.proxy-abc123.us-east-2.rds.amazonaws.com' } }

      it 'raises on proxy pattern' do
        expect { provider }.to raise_error(
          AwsRubyDatabaseDriverWrapper::Errors::AwsError, /not supported for RDS Proxy/
        )
      end
    end
  end

  describe '#refresh' do
    context 'when topology is cached' do
      let(:cached_topology) do
        [AwsRubyDatabaseDriverWrapper::Host::HostInfo.new(
          host: 'writer.abc123.us-east-2.rds.amazonaws.com', port: 5432,
          role: AwsRubyDatabaseDriverWrapper::Host::HostRole::WRITER, id: 'writer-1'
        )]
      end

      before do
        storage_service.set(:topology, provider.cluster_id, cached_topology)
      end

      it 'returns cached topology without hitting the monitor' do
        result = provider.refresh
        expect(result).to eq(cached_topology)
      end
    end

    context 'when cache is empty and monitor fails' do
      before do
        allow(topology_utils).to receive(:query_topology).and_return(nil)
        allow(db_dialect).to receive(:host_role).and_return(:writer)
      end

      it 'falls back to initial_host_list' do
        result = provider.refresh
        expect(result).to eq([initial_host_info])
      end
    end
  end

  describe '#force_refresh' do
    before do
      allow(topology_utils).to receive(:query_topology).and_return(nil)
      allow(db_dialect).to receive(:host_role).and_return(:writer)
    end

    it 'returns nil on monitor timeout' do
      # Monitor will fail to find topology (mocked to return nil)
      result = provider.force_refresh(false, 0.1)
      expect(result).to be_nil
    end
  end

  describe '#stop_monitor' do
    it 'calls stop_and_remove on monitor_service' do
      allow(monitor_service).to receive(:stop_and_remove)
      provider.stop_monitor
      expect(monitor_service).to have_received(:stop_and_remove).with(:cluster_topology, provider.cluster_id)
    end
  end

  describe 'monitoring property prefix mechanism' do
    let(:prefixed_props) do
      { 'topology-monitoring-' => { connect_timeout: 3, socket_timeout: 2 } }
    end

    it 'builds monitoring_driver_props with overridden values' do
      props = provider.instance_variable_get(:@monitoring_driver_props)
      expect(props[:connect_timeout]).to eq(3)
      expect(props[:socket_timeout]).to eq(2)
      expect(props[:user]).to eq('admin')
    end

    it 'produces empty monitoring_wrapper_props when no wrapper overrides' do
      expect(provider.instance_variable_get(:@monitoring_wrapper_props)).to eq({})
    end
  end

  describe 'monitoring wrapper overrides' do
    let(:prefixed_props) do
      { 'topology-monitoring-' => { cluster_topology_refresh_rate_ms: 1000 } }
    end

    it 'separates wrapper props from driver props' do
      wrapper = provider.instance_variable_get(:@monitoring_wrapper_props)
      driver = provider.instance_variable_get(:@monitoring_driver_props)
      expect(wrapper[:cluster_topology_refresh_rate_ms]).to eq(1000)
      expect(driver).not_to have_key(:cluster_topology_refresh_rate_ms)
    end
  end
end
