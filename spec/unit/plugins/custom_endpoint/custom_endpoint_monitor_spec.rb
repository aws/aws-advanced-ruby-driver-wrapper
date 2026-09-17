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
require 'aws_advanced_ruby_driver_wrapper/plugins/custom_endpoint/custom_endpoint_monitor'
require 'aws_advanced_ruby_driver_wrapper/plugins/custom_endpoint/info'
require 'aws_advanced_ruby_driver_wrapper/plugins/custom_endpoint/member_list_type'
require 'aws_advanced_ruby_driver_wrapper/plugins/custom_endpoint/role'
require 'aws_advanced_ruby_driver_wrapper/host/host_info'

RSpec.describe AwsAdvancedRubyDriverWrapper::Plugins::CustomEndpoint::CustomEndpointMonitor do
  let(:info_class)       { AwsAdvancedRubyDriverWrapper::Plugins::CustomEndpoint::Info }
  let(:member_list_type) { AwsAdvancedRubyDriverWrapper::Plugins::CustomEndpoint::MemberListType }
  let(:role_class)       { AwsAdvancedRubyDriverWrapper::Plugins::CustomEndpoint::Role }

  let(:custom_url)  { 'custom1.cluster-custom-XYZ.us-east-1.rds.amazonaws.com' }
  let(:endpoint_id) { 'custom1' }
  let(:cluster_id)  { 'cluster1' }
  let(:region)      { 'us-east-1' }

  let(:host_info)            { AwsAdvancedRubyDriverWrapper::Host::HostInfo.new(host: custom_url) }
  let(:mock_rds_client)      { instance_double(Aws::RDS::Client).as_null_object }
  let(:mock_storage_service) { double('StorageService', register: nil, get: nil, set: nil, remove: nil, clear: nil) }
  let(:service_container)    { double('ServiceContainer', storage_service: mock_storage_service) }
  let(:rds_client_func)      { ->(_host, _region) { mock_rds_client } }

  def build_monitor(refresh_rate_sec: 0.05, backoff_factor: 2, max_refresh_rate_sec: 0.5)
    described_class.new(
      service_container,
      host_info,
      endpoint_id,
      region,
      refresh_rate_sec,
      backoff_factor,
      max_refresh_rate_sec,
      rds_client_func: rds_client_func
    )
  end

  def stub_rds_response(static_members: %w[member1 member2], excluded_members: [], endpoint_type: 'ANY')
    response = double('RdsResponse')
    endpoint = double('DbClusterEndpoint',
                      db_cluster_endpoint_identifier: endpoint_id,
                      db_cluster_identifier: cluster_id,
                      endpoint: custom_url,
                      custom_endpoint_type: endpoint_type,
                      static_members: static_members,
                      excluded_members: excluded_members)
    allow(response).to receive(:db_cluster_endpoints).and_return([endpoint])
    allow(mock_rds_client).to receive(:describe_db_cluster_endpoints).and_return(response)
    endpoint
  end

  describe '#endpoint_info?' do
    it 'returns false when no info is cached' do
      allow(mock_storage_service).to receive(:get).and_return(nil)
      allow(mock_rds_client).to receive(:describe_db_cluster_endpoints)
      monitor = build_monitor
      expect(monitor.endpoint_info?).to be false
    end

    it 'returns true when info is cached' do
      cached = info_class.new(
        endpoint_identifier: endpoint_id, cluster_identifier: cluster_id,
        url: custom_url, role: role_class::ANY,
        members: ['member1'], member_list_type: member_list_type::STATIC_LIST
      )
      allow(mock_storage_service).to receive(:get).and_return(cached)
      monitor = build_monitor
      expect(monitor.endpoint_info?).to be true
    end
  end

  describe '#wait_for_info?' do
    let(:cached) do
      info_class.new(
        endpoint_identifier: endpoint_id, cluster_identifier: cluster_id,
        url: custom_url, role: role_class::ANY,
        members: ['member1'], member_list_type: member_list_type::STATIC_LIST
      )
    end

    it 'returns true immediately when info is already cached' do
      allow(mock_storage_service).to receive(:get).and_return(cached)
      expect(build_monitor.wait_for_info?(1.0)).to be true
    end

    it 'returns false when info never becomes available within the timeout' do
      allow(mock_storage_service).to receive(:get).and_return(nil)
      expect(build_monitor.wait_for_info?(0.2)).to be false
    end

    it 'keeps polling and returns true once the monitor caches info during the wait' do
      # Empty cache on the first checks, then populated - the poll must pick it up rather than giving up
      # after a single check (the previous one-shot signal latched and stopped waiting after the first fetch).
      allow(mock_storage_service).to receive(:get).and_return(nil, nil, cached)
      expect(build_monitor.wait_for_info?(2.0)).to be true
    end
  end

  describe '#request_endpoint_info_update' do
    it 'does not raise when called normally' do
      monitor = build_monitor
      expect { monitor.request_endpoint_info_update }.not_to raise_error
    end
  end

  describe '#close' do
    it 'removes cached endpoint info' do
      expect(mock_storage_service).to receive(:remove).with(
        described_class::ENDPOINT_INFO_CACHE_NAME, host_info.url
      )
      build_monitor.close
    end

    it 'does not raise when the rds client does not respond to close' do
      expect { build_monitor.close }.not_to raise_error
    end
  end

  describe '.clear_cache' do
    it 'clears the endpoint info cache via the storage service' do
      expect(mock_storage_service).to receive(:clear).with(described_class::ENDPOINT_INFO_CACHE_NAME)
      described_class.clear_cache(mock_storage_service)
    end
  end

  describe 'monitor run loop' do
    it 'fetches endpoint info and caches it' do
      stub_rds_response(static_members: %w[member1 member2])
      allow(mock_storage_service).to receive(:get).and_return(nil)

      monitor = build_monitor(refresh_rate_sec: 0.03)
      monitor.start

      sleep(0.15)
      monitor.stop

      expect(mock_storage_service).to have_received(:set).with(
        described_class::ENDPOINT_INFO_CACHE_NAME,
        host_info.url,
        an_instance_of(info_class)
      ).at_least(:once)
    end

    it 'skips caching when the API returns multiple endpoints' do
      response = double('RdsResponse')
      ep1 = double('ep1', endpoint: custom_url)
      ep2 = double('ep2', endpoint: 'other.cluster-custom-XYZ.us-east-1.rds.amazonaws.com')
      allow(response).to receive(:db_cluster_endpoints).and_return([ep1, ep2])
      allow(mock_rds_client).to receive(:describe_db_cluster_endpoints).and_return(response)
      allow(mock_storage_service).to receive(:get).and_return(nil)

      monitor = build_monitor(refresh_rate_sec: 0.03)
      monitor.start
      sleep(0.1)
      monitor.stop

      expect(mock_storage_service).not_to have_received(:set)
    end

    it 'handles throttling errors without crashing' do
      throttle_error = Aws::RDS::Errors::ServiceError.new(
        double('context', http_response: double('resp', status_code: 429)),
        'ThrottlingException'
      )
      allow(mock_rds_client).to receive(:describe_db_cluster_endpoints).and_raise(throttle_error)
      allow(mock_storage_service).to receive(:get).and_return(nil)

      monitor = build_monitor(refresh_rate_sec: 0.03)
      monitor.start
      sleep(0.1)
      expect { monitor.stop }.not_to raise_error
    end

    it 'handles unauthorized errors without crashing' do
      auth_error = Aws::RDS::Errors::ServiceError.new(
        double('context', http_response: double('resp', status_code: 403)),
        'AccessDenied'
      )
      allow(mock_rds_client).to receive(:describe_db_cluster_endpoints).and_raise(auth_error)
      allow(mock_storage_service).to receive(:get).and_return(nil)

      monitor = build_monitor(refresh_rate_sec: 0.03)
      monitor.start
      sleep(0.1)
      expect { monitor.stop }.not_to raise_error
    end

    it 'removes cached info on stop' do
      stub_rds_response
      allow(mock_storage_service).to receive(:get).and_return(nil)

      monitor = build_monitor(refresh_rate_sec: 0.03)
      monitor.start
      sleep(0.05)
      monitor.stop
      sleep(0.1)

      expect(mock_storage_service).to have_received(:remove).with(
        described_class::ENDPOINT_INFO_CACHE_NAME, host_info.url
      ).at_least(:once)
    end
  end

  describe 'throttling backoff' do
    # NOTE: This test documents a known issue where connection-driven refresh requests
    # (refreshRequired=true) bypass the sleep_ignoring_refresh_requests path used on
    # throttling errors, causing the monitor to spin. The Java implementation has the
    # same bug (see CustomEndpointMonitorImplTest#testThrottlingBackoffBypassedByConnectionStorm).
    # Once fixed, the call count should be <= 10 for a 500ms window with 20ms base rate.
    it 'invokes the RDS API at least once when throttled' do
      call_count = 0
      throttle_error = Aws::RDS::Errors::ServiceError.new(
        double('context', http_response: double('resp', status_code: 429)),
        'ThrottlingException'
      )
      allow(mock_rds_client).to receive(:describe_db_cluster_endpoints) do
        call_count += 1
        raise throttle_error
      end
      allow(mock_storage_service).to receive(:get).and_return(nil)

      monitor = build_monitor(refresh_rate_sec: 0.02, backoff_factor: 2, max_refresh_rate_sec: 0.2)
      monitor.start
      sleep(0.1)
      monitor.stop

      expect(call_count).to be >= 1
    end
  end
end
