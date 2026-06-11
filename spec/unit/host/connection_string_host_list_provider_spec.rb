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
require 'aws_ruby_database_driver_wrapper/host/connection_string_host_list_provider'
require 'aws_ruby_database_driver_wrapper/host/host_info'
require 'aws_ruby_database_driver_wrapper/host/host_role'
require 'aws_ruby_database_driver_wrapper/services/service_container'
require 'aws_ruby_database_driver_wrapper/services/connection_service'
require 'aws_ruby_database_driver_wrapper/errors'

RSpec.describe AwsRubyDatabaseDriverWrapper::Host::ConnectionStringHostListProvider do
  let(:host_info_class) { AwsRubyDatabaseDriverWrapper::Host::HostInfo }
  let(:host_role) { AwsRubyDatabaseDriverWrapper::Host::HostRole }

  let(:initial_host_info) do
    host_info_class.new(host: 'myhost', port: '5432')
  end

  let(:config) do
    instance_double('ConnectionConfig',
                    multi_host_url?: false,
                    original_host: 'myhost',
                    original_port: '5432')
  end

  let(:connection_service) do
    instance_double('ConnectionService',
                    initial_host_info: initial_host_info,
                    config: config)
  end

  let(:service_container) do
    instance_double('ServiceContainer', connection_service: connection_service)
  end

  subject(:provider) { described_class.new(service_container: service_container) }

  describe '#refresh' do
    context 'single-host connection' do
      it 'returns an array with the initial host info' do
        hosts = provider.refresh
        expect(hosts).to eq([initial_host_info])
      end

      it 'returns a dup so the internal list is not mutated' do
        hosts1 = provider.refresh
        hosts2 = provider.refresh
        expect(hosts1).not_to be(hosts2)
        expect(hosts1).to eq(hosts2)
      end
    end

    context 'multi-host connection with per-host ports' do
      let(:config) do
        instance_double('ConnectionConfig',
                        multi_host_url?: true,
                        original_host: 'host1,host2',
                        original_port: '5432,5433')
      end

      it 'returns a HostInfo for each host with correct ports' do
        hosts = provider.refresh
        expect(hosts.length).to eq(2)

        expect(hosts[0].host).to eq('host1')
        expect(hosts[0].port).to eq('5432')
        expect(hosts[0].role).to eq(host_role::UNKNOWN)

        expect(hosts[1].host).to eq('host2')
        expect(hosts[1].port).to eq('5433')
        expect(hosts[1].role).to eq(host_role::UNKNOWN)
      end
    end

    context 'multi-host connection with mixed ports (first missing)' do
      let(:config) do
        instance_double('ConnectionConfig',
                        multi_host_url?: true,
                        original_host: 'host1,host2',
                        original_port: ',5433')
      end

      it 'uses NO_PORT for hosts without an explicit port' do
        hosts = provider.refresh
        expect(hosts.length).to eq(2)

        expect(hosts[0].host).to eq('host1')
        expect(hosts[0].port).to eq(host_info_class::NO_PORT)
        expect(hosts[0].role).to eq(host_role::UNKNOWN)

        expect(hosts[1].host).to eq('host2')
        expect(hosts[1].port).to eq('5433')
        expect(hosts[1].role).to eq(host_role::UNKNOWN)
      end
    end

    context 'multi-host connection with mixed ports (last missing)' do
      let(:config) do
        instance_double('ConnectionConfig',
                        multi_host_url?: true,
                        original_host: 'host1,host2',
                        original_port: '5432,')
      end

      it 'uses NO_PORT for the trailing host without a port' do
        hosts = provider.refresh
        expect(hosts.length).to eq(2)

        expect(hosts[0].host).to eq('host1')
        expect(hosts[0].port).to eq('5432')

        expect(hosts[1].host).to eq('host2')
        expect(hosts[1].port).to eq(host_info_class::NO_PORT)
      end
    end

    context 'multi-host connection with no ports at all' do
      let(:config) do
        instance_double('ConnectionConfig',
                        multi_host_url?: true,
                        original_host: 'host1,host2',
                        original_port: ',')
      end

      it 'uses NO_PORT for all hosts' do
        hosts = provider.refresh
        expect(hosts.length).to eq(2)

        expect(hosts[0].host).to eq('host1')
        expect(hosts[0].port).to eq(host_info_class::NO_PORT)

        expect(hosts[1].host).to eq('host2')
        expect(hosts[1].port).to eq(host_info_class::NO_PORT)
      end
    end

    context 'multi-host connection with single port (from hash input)' do
      let(:config) do
        instance_double('ConnectionConfig',
                        multi_host_url?: true,
                        original_host: 'host1,host2,host3',
                        original_port: '5433')
      end

      it 'assigns the single port to all hosts' do
        hosts = provider.refresh
        expect(hosts.length).to eq(3)

        expect(hosts[0].host).to eq('host1')
        expect(hosts[0].port).to eq('5433')

        expect(hosts[1].host).to eq('host2')
        expect(hosts[1].port).to eq('5433')

        expect(hosts[2].host).to eq('host3')
        expect(hosts[2].port).to eq('5433')
      end
    end

    context 'multi-host connection with three hosts and three ports' do
      let(:config) do
        instance_double('ConnectionConfig',
                        multi_host_url?: true,
                        original_host: 'h1,h2,h3',
                        original_port: '5432,5433,5434')
      end

      it 'correctly assigns each port positionally' do
        hosts = provider.refresh
        expect(hosts.length).to eq(3)

        expect(hosts[0].host).to eq('h1')
        expect(hosts[0].port).to eq('5432')

        expect(hosts[1].host).to eq('h2')
        expect(hosts[1].port).to eq('5433')

        expect(hosts[2].host).to eq('h3')
        expect(hosts[2].port).to eq('5434')
      end
    end

    context 'multi-host connection with nil original_port' do
      let(:config) do
        instance_double('ConnectionConfig',
                        multi_host_url?: true,
                        original_host: 'host1,host2',
                        original_port: nil)
      end

      it 'uses NO_PORT for all hosts' do
        hosts = provider.refresh
        expect(hosts.length).to eq(2)

        expect(hosts[0].port).to eq(host_info_class::NO_PORT)
        expect(hosts[1].port).to eq(host_info_class::NO_PORT)
      end
    end
  end

  describe '#force_refresh' do
    it 'returns the same host list as refresh' do
      expect(provider.force_refresh).to eq(provider.refresh)
    end
  end

  describe '#cluster_id' do
    it 'returns a placeholder value' do
      expect(provider.cluster_id).to eq('<none>')
    end
  end

  describe '#stop_monitor' do
    it 'is a no-op and does not raise' do
      expect { provider.stop_monitor }.not_to raise_error
    end
  end
end
