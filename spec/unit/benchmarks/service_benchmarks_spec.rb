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
require_relative '../../../benchmarks/support/service_fixtures'

# Guards the assumptions the plugin service benchmark relies on: that the real services can be wired
# with the cheap stubs, and that each benchmarked method still exists and behaves the way the
# benchmark drives it. The benchmark is not run in CI, so API drift in any of these services fails
# here instead of the benchmark silently breaking.
module AwsAdvancedRubyDriverWrapper
  RSpec.describe Benchmarks::PluginServiceFixtures do
    let(:plain) { described_class.build(with_allow_list: false) }
    let(:allow_list) { described_class.build(with_allow_list: true) }

    after do
      plain.shutdown
      allow_list.shutdown
    end

    it 'exposes the current connection and host through the connection service' do
      expect(plain.connection_service.current_connection).to be(described_class::STUB_CONNECTION)

      host = plain.connection_service.current_host_info
      expect(host.id).to eq('instance-0')
      expect(host.role).to eq(Host::HostRole::WRITER)
    end

    it 'populates the topology through the real refresh path' do
      hosts = plain.host_service.all_hosts
      expect(hosts.length).to eq(described_class::HOST_COUNT)
      expect(hosts.first.role).to eq(Host::HostRole::WRITER)
      expect(hosts.count { |h| h.role == Host::HostRole::READER }).to eq(described_class::HOST_COUNT - 1)
    end

    it 'returns the whole topology from hosts when no allow list is registered' do
      expect(plain.host_service.hosts).to eq(plain.host_service.all_hosts)
    end

    it 'filters hosts down to the allow list when one is registered' do
      filtered = allow_list.host_service.hosts
      expect(filtered.map(&:id)).to contain_exactly('instance-1', 'instance-2', 'instance-3')
    end

    it 'selects an available reader through the random strategy' do
      selected = plain.host_service.select_host(plain.host_service.all_hosts, Host::HostRole::READER, 'random')
      expect(selected.role).to eq(Host::HostRole::READER)
    end

    it 'updates host availability in the topology' do
      plain.host_service.set_availability(plain.reader_host, Host::HostAvailability::UNAVAILABLE)
      updated = plain.host_service.all_hosts.find { |h| h.id == plain.reader_host.id }
      expect(updated.availability).to eq(Host::HostAvailability::UNAVAILABLE)
    end

    it 'tracks transaction state and resets it' do
      service = plain.session_state_service
      expect(service.in_transaction?).to be(false)

      service.update_transaction_state('connection.query', ['BEGIN'], true)
      expect(service.in_transaction?).to be(true)

      service.reset
      expect(service.in_transaction?).to be(false)
      expect(service.autocommit?).to be(true)
    end

    it 'reads the thread-local call context, which is nil outside a call' do
      expect(plain.plugin_manager.current_call_context).to be_nil
    end

    it 'classifies network errors by SQLSTATE' do
      expect(plain.error_handler.network_error_by_sql_state?('08006')).to be(true)
      expect(plain.error_handler.network_error_by_sql_state?('00000')).to be(false)
    end
  end
end
