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
require 'aws_ruby_database_driver_wrapper/services/host_service'
require 'aws_ruby_database_driver_wrapper/host/host_info'
require 'aws_ruby_database_driver_wrapper/host/host_role'
require 'aws_ruby_database_driver_wrapper/host/random_host_selector'
require 'aws_ruby_database_driver_wrapper/errors'

RSpec.describe AwsRubyDatabaseDriverWrapper::Services::HostService do
  let(:host_permissions) do
    instance_double('HostPermissions', allowed_host_ids: [], blocked_host_ids: [], required_role: nil)
  end

  let(:storage_service) { instance_double('StorageService') }

  let(:dialect) { instance_double('Dialect') }
  let(:dialect_service) { instance_double('DialectService', db_dialect: dialect) }

  let(:service_container) do
    instance_double('ServiceContainer', storage_service: storage_service, dialect_service: dialect_service)
  end

  let(:service) { described_class.new(service_container) }

  let(:writer) do
    AwsRubyDatabaseDriverWrapper::Host::HostInfo.new(
      host: 'writer-host',
      port: 5432,
      role: AwsRubyDatabaseDriverWrapper::Host::HostRole::WRITER,
      id: 'writer-id'
    )
  end

  let(:reader) do
    AwsRubyDatabaseDriverWrapper::Host::HostInfo.new(
      host: 'reader-host',
      port: 5432,
      role: AwsRubyDatabaseDriverWrapper::Host::HostRole::READER,
      id: 'reader-id'
    )
  end

  let(:hosts) { [writer, reader] }

  describe '#select_host' do
    context 'with a default strategy' do
      it 'delegates to the registered selector' do
        result = service.select_host([reader], AwsRubyDatabaseDriverWrapper::Host::HostRole::READER, 'random')
        expect(result).to eq(reader)
      end
    end

    context 'with an unknown strategy' do
      it 'raises an error' do
        expect { service.select_host(hosts, nil, 'nonexistent') }
          .to raise_error(AwsRubyDatabaseDriverWrapper::Errors::AwsError, /Unsupported host selection strategy/)
      end
    end
  end

  describe '.register_host_selector' do
    # The registry is per process, so a strategy registered by one example would leak into the next.
    after { described_class.reset_host_selectors }

    it 'makes a new strategy available for selection' do
      custom_selector = instance_double('CustomSelector')
      allow(custom_selector).to receive(:select_host).and_return(reader)

      described_class.register_host_selector('custom', custom_selector)
      result = service.select_host(hosts, nil, 'custom')

      expect(result).to eq(reader)
    end

    it 'shares the registered strategy with other HostService instances' do
      custom_selector = instance_double('CustomSelector')
      allow(custom_selector).to receive(:select_host).and_return(reader)

      described_class.register_host_selector('custom', custom_selector)
      other_service = described_class.new(service_container)

      expect(other_service.select_host(hosts, nil, 'custom')).to eq(reader)
    end

    it 'raises an error when overriding a default strategy' do
      custom_selector = instance_double('CustomSelector')

      expect { described_class.register_host_selector('random', custom_selector) }
        .to raise_error(AwsRubyDatabaseDriverWrapper::Errors::AwsError, /Cannot override default host selection strategy/)
    end
  end

  describe '#hosts' do
    before do
      service.instance_variable_set(:@all_hosts, hosts)
      service.instance_variable_set(:@initial_host_info, writer)
      allow(storage_service).to receive(:get).with(:host_permissions, writer.url).and_return(host_permissions)
    end

    context 'with no filtering rules' do
      it 'returns all hosts' do
        expect(service.hosts).to eq(hosts)
      end
    end
  end

  describe '#set_availability' do
    before do
      service.instance_variable_set(:@all_hosts, hosts)
    end

    it 'updates availability when matched by id' do
      service.set_availability(writer, :unavailable)
      expect(writer.raw_availability).to eq(:unavailable)
    end

    it 'updates availability when matched by host name (case-insensitive)' do
      lookup_host = AwsRubyDatabaseDriverWrapper::Host::HostInfo.new(
        host: 'READER-HOST',
        port: 5432,
        id: 'different-id'
      )
      service.set_availability(lookup_host, :unavailable)
      expect(reader.raw_availability).to eq(:unavailable)
    end

    it 'does nothing when no matching host is found' do
      unknown_host = AwsRubyDatabaseDriverWrapper::Host::HostInfo.new(
        host: 'unknown-host',
        port: 5432,
        id: 'unknown-id'
      )
      expect { service.set_availability(unknown_host, :unavailable) }.not_to raise_error
    end
  end

  describe '#refresh_host_list' do
    let(:host_list_provider) { instance_double('HostListProvider') }

    before do
      service.host_list_provider = host_list_provider
      service.instance_variable_set(:@all_hosts, [writer])
    end

    it 'updates the host list when the provider returns new hosts' do
      allow(host_list_provider).to receive(:refresh).and_return(hosts)
      service.refresh_host_list
      expect(service.all_hosts).to eq(hosts)
    end

    it 'does nothing when the provider returns nil' do
      allow(host_list_provider).to receive(:refresh).and_return(nil)
      service.refresh_host_list
      expect(service.all_hosts).to eq([writer])
    end

    it 'does nothing when the provider returns the same hosts' do
      allow(host_list_provider).to receive(:refresh).and_return([writer])
      service.refresh_host_list
      expect(service.all_hosts).to eq([writer])
    end
  end

  describe '#force_refresh_host_list?' do
    let(:host_list_provider) { instance_double('HostListProvider') }

    before do
      service.host_list_provider = host_list_provider
      service.instance_variable_set(:@all_hosts, [writer])
    end

    it 'updates the host list when the provider returns new hosts' do
      allow(host_list_provider).to receive(:force_refresh).with(false, 5.0).and_return(hosts)
      service.force_refresh_host_list?
      expect(service.all_hosts).to eq(hosts)
    end

    it 'passes verify_writer and timeout_sec to the provider' do
      allow(host_list_provider).to receive(:force_refresh).with(true, 3.0).and_return(hosts)
      service.force_refresh_host_list?(verify_writer: true, timeout_sec: 3.0)
      expect(service.all_hosts).to eq(hosts)
    end

    it 'does nothing when the provider returns nil' do
      allow(host_list_provider).to receive(:force_refresh).with(false, 5.0).and_return(nil)
      service.force_refresh_host_list?
      expect(service.all_hosts).to eq([writer])
    end
  end

  describe '#identify_host' do
    let(:host_list_provider) { instance_double('HostListProvider') }
    let(:connection) { instance_double('Connection') }

    before do
      service.host_list_provider = host_list_provider
    end

    it 'returns the host matching the queried id' do
      allow(dialect).to receive(:instance_identity).with(connection).and_return(['reader-id', nil])
      allow(host_list_provider).to receive(:refresh).and_return(hosts)

      result = service.identify_host(connection)
      expect(result).to eq(reader)
    end

    it 'returns nil when instance_identity returns nil' do
      allow(dialect).to receive(:instance_identity).with(connection).and_return([nil, nil])
      allow(host_list_provider).to receive(:refresh).and_return(hosts)

      result = service.identify_host(connection)
      expect(result).to be_nil
    end
  end
end
