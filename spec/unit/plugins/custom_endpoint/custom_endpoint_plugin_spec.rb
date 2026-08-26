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
require 'aws-sdk-rds'
require 'aws_ruby_driver_wrapper/plugins/custom_endpoint/custom_endpoint_plugin'
require 'aws_ruby_driver_wrapper/plugins/custom_endpoint/custom_endpoint_monitor'
require 'aws_ruby_driver_wrapper/host/host_info'
require 'aws_ruby_driver_wrapper/errors'
require 'concurrent'

RSpec.describe AwsRubyDriverWrapper::Plugins::CustomEndpoint::CustomEndpointPlugin do
  CUSTOM_ENDPOINT_URL   = 'my-custom.cluster-custom-XYZ.us-east-1.rds.amazonaws.com'
  WRITER_CLUSTER_URL    = 'writer.cluster-XYZ.us-east-1.rds.amazonaws.com'
  MONITOR_TYPE          = described_class::MONITOR_TYPE
  ENDPOINT_INFO_CACHE   = AwsRubyDriverWrapper::Plugins::CustomEndpoint::CustomEndpointMonitor::ENDPOINT_INFO_CACHE_NAME

  let(:custom_host_info) { AwsRubyDriverWrapper::Host::HostInfo.new(host: CUSTOM_ENDPOINT_URL) }
  let(:writer_host_info) { AwsRubyDriverWrapper::Host::HostInfo.new(host: WRITER_CLUSTER_URL) }

  let(:mock_monitor)         { instance_double(AwsRubyDriverWrapper::Plugins::CustomEndpoint::CustomEndpointMonitor) }
  let(:mock_storage_service) { double('StorageService', register: nil, get: nil, set: nil, clear: nil) }
  let(:mock_monitor_service) { double('MonitorService', register_type: nil) }
  let(:mock_driver_dialect)  { double('DriverDialect', network_bound_methods: Set['connection.query']) }
  let(:mock_dialect_service) { double('DialectService', driver_dialect: mock_driver_dialect) }

  let(:service_container) do
    double('ServiceContainer',
           storage_service: mock_storage_service,
           monitor_service: mock_monitor_service,
           dialect_service: mock_dialect_service)
  end

  def build_plugin(extra_props = {})
    props = Concurrent::Map.new
    extra_props.each { |k, v| props[k] = v }
    allow(Aws::RDS::Client).to receive(:new)
    described_class.new(service_container, props)
  end

  def build_plugin_with_monitor(extra_props = {})
    plugin = build_plugin(extra_props)
    allow(mock_monitor_service).to receive(:run_if_absent).and_return(mock_monitor)
    plugin
  end

  describe '#initialize' do
    it 'registers the monitor type with the monitor service' do
      expect(mock_monitor_service).to receive(:register_type).with(MONITOR_TYPE, anything)
      build_plugin
    end

    it 'registers the endpoint info cache with the storage service' do
      expect(mock_storage_service).to receive(:register).with(ENDPOINT_INFO_CACHE, anything)
      build_plugin
    end

    it 'subscribes to connect and network-bound methods' do
      plugin = build_plugin
      expect(plugin.subscribed_methods).to include('connect')
      expect(plugin.subscribed_methods).to include('connection.query')
    end

    it 'raises LoadError when aws-sdk-rds is not available' do
      allow_any_instance_of(described_class).to receive(:ensure_aws_sdk!).and_raise(
        LoadError, 'cannot load such file -- aws-sdk-rds'
      )
      expect { build_plugin }.to raise_error(LoadError, /aws-sdk-rds/)
    end
  end

  describe '#connect' do
    context 'when host is not a custom endpoint' do
      it 'calls the pipeline without creating a monitor' do
        plugin = build_plugin
        pipeline = -> { :connected }
        expect(mock_monitor_service).not_to receive(:run_if_absent)
        result = plugin.connect(writer_host_info, {}, true, pipeline)
        expect(result).to eq(:connected)
      end
    end

    context 'when host is a custom endpoint' do
      it 'creates a monitor and calls the pipeline' do
        plugin = build_plugin_with_monitor(wait_for_custom_endpoint_info: 'false')
        pipeline = -> { :connected }
        expect(mock_monitor_service).to receive(:run_if_absent).and_return(mock_monitor)
        result = plugin.connect(custom_host_info, {}, true, pipeline)
        expect(result).to eq(:connected)
      end

      it 'does not wait for endpoint info when wait_for_custom_endpoint_info is false' do
        plugin = build_plugin_with_monitor(wait_for_custom_endpoint_info: 'false')
        pipeline = -> { :connected }
        expect(mock_monitor).not_to receive(:endpoint_info?)
        plugin.connect(custom_host_info, {}, true, pipeline)
      end

      it 'calls the pipeline after endpoint info is available' do
        plugin = build_plugin_with_monitor(wait_for_custom_endpoint_info: 'true')
        allow(mock_monitor).to receive(:endpoint_info?).and_return(true)
        pipeline = -> { :connected }
        result = plugin.connect(custom_host_info, {}, true, pipeline)
        expect(result).to eq(:connected)
      end

      it 'raises AwsError when endpoint info is not available within timeout' do
        plugin = build_plugin_with_monitor(
          wait_for_custom_endpoint_info: 'true',
          wait_for_custom_endpoint_info_timeout_ms: '1'
        )
        allow(mock_monitor).to receive(:endpoint_info?).and_return(false)
        allow(mock_monitor).to receive(:request_endpoint_info_update)
        allow(mock_monitor).to receive(:wait_for_info?).and_return(false)
        pipeline = -> { :connected }
        expect do
          plugin.connect(custom_host_info, {}, true, pipeline)
        end.to raise_error(AwsRubyDriverWrapper::Errors::AwsError, /timed out/)
      end

      it 'raises AwsError when endpoint ID cannot be parsed from host' do
        bad_host = AwsRubyDriverWrapper::Host::HostInfo.new(
          host: 'not-a-custom-endpoint.cluster-custom-XYZ.us-east-1.rds.amazonaws.com'
        )
        allow(AwsRubyDriverWrapper::Utils::RdsUtils).to receive(:rds_custom_cluster_dns?).and_return(true)
        allow(AwsRubyDriverWrapper::Utils::RdsUtils).to receive(:rds_cluster_id).and_return(nil)
        plugin = build_plugin
        expect do
          plugin.connect(bad_host, {}, true, -> {})
        end.to raise_error(AwsRubyDriverWrapper::Errors::AwsError, /endpoint identifier/)
      end

      it 'raises AwsError when region cannot be determined' do
        allow(AwsRubyDriverWrapper::Utils::RdsUtils).to receive(:rds_custom_cluster_dns?).and_return(true)
        allow(AwsRubyDriverWrapper::Utils::RdsUtils).to receive(:rds_cluster_id).and_return('my-custom')
        allow(AwsRubyDriverWrapper::Utils::RdsUtils).to receive(:rds_region).and_return(nil)
        plugin = build_plugin
        expect do
          plugin.connect(custom_host_info, {}, true, -> {})
        end.to raise_error(AwsRubyDriverWrapper::Errors::AwsError, /region/)
      end

      it 'uses custom_endpoint_region prop when set' do
        plugin = build_plugin_with_monitor(
          wait_for_custom_endpoint_info: 'false',
          custom_endpoint_region: 'eu-west-1'
        )
        pipeline = -> { :connected }
        # Should not raise even though the host URL has a different region
        expect { plugin.connect(custom_host_info, {}, true, pipeline) }.not_to raise_error
      end
    end
  end

  describe '#execute' do
    context 'when no custom endpoint host has been set (non-custom connection)' do
      it 'calls the pipeline without creating a monitor' do
        plugin = build_plugin
        pipeline = -> { :result }
        expect(mock_monitor_service).not_to receive(:run_if_absent)
        result = plugin.execute('connection.query', pipeline)
        expect(result).to eq(:result)
      end
    end

    context 'when a custom endpoint host is set' do
      it 'creates a monitor and calls the pipeline' do
        plugin = build_plugin_with_monitor(wait_for_custom_endpoint_info: 'false')
        # Trigger connect to set @custom_endpoint_host
        allow(mock_monitor).to receive(:endpoint_info?).and_return(true)
        plugin.connect(custom_host_info, {}, true, -> {})

        pipeline = -> { :result }
        expect(mock_monitor_service).to receive(:run_if_absent).and_return(mock_monitor)
        result = plugin.execute('connection.query', pipeline)
        expect(result).to eq(:result)
      end

      it 'raises AwsError when endpoint info times out during execute' do
        plugin = build_plugin_with_monitor(
          wait_for_custom_endpoint_info: 'true',
          wait_for_custom_endpoint_info_timeout_ms: '1'
        )
        allow(mock_monitor).to receive(:endpoint_info?).and_return(true)
        plugin.connect(custom_host_info, {}, true, -> {})

        allow(mock_monitor).to receive(:endpoint_info?).and_return(false)
        allow(mock_monitor).to receive(:request_endpoint_info_update)
        allow(mock_monitor).to receive(:wait_for_info?).and_return(false)

        expect do
          plugin.execute('connection.query', -> {})
        end.to raise_error(AwsRubyDriverWrapper::Errors::AwsError, /timed out/)
      end
    end
  end

  describe '.clear_cache' do
    it 'delegates to the storage service with ENDPOINT_INFO_CACHE_NAME' do
      expect(mock_storage_service).to receive(:clear).with(ENDPOINT_INFO_CACHE)
      described_class.clear_cache(mock_storage_service)
    end
  end

  describe '#subscribed_methods' do
    it 'includes connect' do
      expect(build_plugin.subscribed_methods).to include('connect')
    end

    it 'includes network-bound methods from the driver dialect' do
      expect(build_plugin.subscribed_methods).to include('connection.query')
    end

    it 'is frozen' do
      expect(build_plugin.subscribed_methods).to be_frozen
    end
  end
end
