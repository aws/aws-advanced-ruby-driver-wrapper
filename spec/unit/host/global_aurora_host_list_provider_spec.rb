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
require 'aws_advanced_ruby_driver_wrapper/host/global_aurora_host_list_provider'
require 'aws_advanced_ruby_driver_wrapper/host/host_info'
require 'aws_advanced_ruby_driver_wrapper/host/host_role'
require 'aws_advanced_ruby_driver_wrapper/utils/events/batching_event_publisher'
require 'aws_advanced_ruby_driver_wrapper/utils/storage/storage_service'
require 'aws_advanced_ruby_driver_wrapper/services/service_container'
require 'aws_advanced_ruby_driver_wrapper/services/monitor_service'

RSpec.describe AwsAdvancedRubyDriverWrapper::Host::GlobalAuroraHostListProvider do
  let(:initial_host_info) do
    AwsAdvancedRubyDriverWrapper::Host::HostInfo.new(
      host: 'x.global-abc123.global.rds.amazonaws.com',
      port: 5432
    )
  end
  let(:instance_templates_str) do
    '[us-east-1]?.abc-123.global.rds.amazonaws.com:5432,[eu-west-1]?.abc123.global.rds.amazonaws.com:5432'
  end
  let(:wrapper_props) do
    {
      global_cluster_instance_host_patterns: instance_templates_str,
      cluster_instance_host_pattern: '?.abc-123.global.rds.amazonaws.com'
    }
  end
  let(:driver_props) { { user: 'admin', password: 'secret', dbname: 'test' } }
  let(:prefixed_wrapper_config) { {} }
  let(:prefixed_driver_config) { {} }
  let(:connection_config) do
    instance_double('ConnectionConfig',
                    wrapper_props: wrapper_props,
                    driver_props: driver_props,
                    prefixed_wrapper_config: prefixed_wrapper_config,
                    prefixed_driver_config: prefixed_driver_config,
                    initial_host_info: initial_host_info)
  end
  let(:connection_service) do
    instance_double('ConnectionService', config: connection_config,
                                         wrapper_props: wrapper_props,
                                         driver_props: driver_props,
                                         prefixed_wrapper_config: prefixed_wrapper_config,
                                         prefixed_driver_config: prefixed_driver_config,
                                         initial_host_info: initial_host_info)
  end
  let(:driver_dialect) do
    instance_double('DriverDialect', connect: nil, close_connection: nil, apply_monitoring_defaults: nil, closed?: false)
  end
  let(:db_dialect) { instance_double('DbDialect') }
  let(:dialect_service) do
    instance_double('DialectService', driver_dialect: driver_dialect, db_dialect: db_dialect, dialect_final?: true)
  end
  let(:event_publisher) do
    AwsAdvancedRubyDriverWrapper::Utils::Events::BatchingEventPublisher.new(message_interval_sec: 60)
  end
  let(:storage_service) do
    AwsAdvancedRubyDriverWrapper::Utils::Storage::StorageService.new(event_publisher: event_publisher)
  end
  let(:monitor_service) do
    AwsAdvancedRubyDriverWrapper::Services::MonitorService.new(event_publisher: event_publisher)
  end
  let(:plugin_manager) { instance_double('PluginManager', internal_connect: nil) }
  let(:service_container) do
    AwsAdvancedRubyDriverWrapper::Services::ServiceContainer.new(
      event_publisher: event_publisher,
      storage_service: storage_service,
      dialect_service: dialect_service,
      connection_service: connection_service,
      monitor_service: monitor_service,
      plugin_manager: plugin_manager
    )
  end
  let(:topology_utils) do
    require 'aws_advanced_ruby_driver_wrapper/utils/global_aurora_topology_utils'
    AwsAdvancedRubyDriverWrapper::Utils::GlobalAuroraTopologyUtils.new(dialect: db_dialect)
  end

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
    it 'parses instance_templates_by_region from wrapper props' do
      templates = provider.instance_templates_by_region
      expect(templates.keys).to contain_exactly('us-east-1', 'eu-west-1')
    end

    it 'builds HostInfo templates with correct host patterns' do
      templates = provider.instance_templates_by_region
      expect(templates['us-east-1'].host).to eq('?.abc-123.global.rds.amazonaws.com')
      expect(templates['eu-west-1'].host).to eq('?.abc123.global.rds.amazonaws.com')
    end

    it 'builds HostInfo templates with correct ports' do
      templates = provider.instance_templates_by_region
      expect(templates['us-east-1'].port).to eq(5432)
      expect(templates['eu-west-1'].port).to eq(5432)
    end

    context 'when global_cluster_instance_host_patterns is missing' do
      let(:wrapper_props) { {} }

      it 'raises an error' do
        expect { provider }.to raise_error(
          AwsAdvancedRubyDriverWrapper::Errors::AwsError,
          /global_cluster_instance_host_patterns is required/
        )
      end
    end
  end

  describe '#force_refresh' do
    it 'returns nil on timeout' do
      result = provider.force_refresh(false, 0.1)
      expect(result).to be_nil
    end
  end

  describe 'inherits RdsHostListProvider behavior' do
    it 'derives cluster_id from wrapper_props' do
      expect(provider.cluster_id).to eq('1')
    end

    it 'auto-derives instance_template from cluster_instance_host_pattern' do
      expect(provider.instance_template.host).to eq('?.abc-123.global.rds.amazonaws.com')
    end

    it 'is a kind of RdsHostListProvider' do
      expect(provider).to be_a(AwsAdvancedRubyDriverWrapper::Host::RdsHostListProvider)
    end
  end
end
