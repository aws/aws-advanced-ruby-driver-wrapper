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
require 'aws_ruby_driver_wrapper/plugins/gdb/gdb_failover_plugin'
require 'aws_ruby_driver_wrapper/plugins/gdb/gdb_failover_mode'
require 'aws_ruby_driver_wrapper/property_definition'
require 'aws_ruby_driver_wrapper/services/service_container'
require 'aws_ruby_driver_wrapper/host/host_info'
require 'aws_ruby_driver_wrapper/host/host_role'
require 'aws_ruby_driver_wrapper/host/host_availability'

RSpec.describe AwsRubyDriverWrapper::Plugins::Gdb::GdbFailoverPlugin do
  let(:host_role) { AwsRubyDriverWrapper::Host::HostRole }
  let(:mode) { AwsRubyDriverWrapper::Plugins::Gdb::GdbFailoverMode }
  let(:errors) { AwsRubyDriverWrapper::Errors }

  # Home region is us-east-1 throughout; us-west-2 is the out-of-home region.
  let(:home_writer) { host_info('writer-1.xyz.us-east-1.rds.amazonaws.com', host_role::WRITER) }
  let(:home_reader) { host_info('reader-1.xyz.us-east-1.rds.amazonaws.com', host_role::READER) }
  let(:remote_writer) { host_info('writer-2.xyz.us-west-2.rds.amazonaws.com', host_role::WRITER) }
  let(:remote_reader) { host_info('reader-2.xyz.us-west-2.rds.amazonaws.com', host_role::READER) }
  let(:regionless_reader) { host_info('reader-3.example.com', host_role::READER) }

  let(:global_endpoint) { host_info('gdb-name.global-xyz.global.rds.amazonaws.com', host_role::WRITER) }

  def host_info(host, role)
    AwsRubyDriverWrapper::Host::HostInfo.new(host: host, port: '5432', role: role)
  end

  let(:connection) { double('connection') }
  let(:new_connection) { double('new_connection') }

  let(:driver_dialect) do
    double('driver_dialect',
           network_bound_methods: Set['connection.exec'],
           closed?: false,
           close_connection: nil,
           execute: nil)
  end

  let(:db_dialect) { double('db_dialect', host_role: host_role::WRITER) }

  let(:dialect_service) do
    double('dialect_service',
           driver_dialect: driver_dialect,
           db_dialect: db_dialect,
           network_error?: false,
           read_only_error?: false)
  end

  let(:session_state_service) do
    double('session_state_service', in_transaction?: false, 'in_transaction=': nil)
  end

  let(:topology) { [home_writer, home_reader, remote_reader] }

  let(:host_service) do
    double('host_service',
           all_hosts: topology,
           hosts: topology,
           refresh_host_list: nil,
           force_refresh_host_list?: true,
           set_availability: nil)
  end

  let(:initial_host) { home_writer }

  let(:connection_service) do
    double('connection_service',
           current_connection: connection,
           current_host_info: home_writer,
           initial_host_info: initial_host,
           'initial_host_info=': nil,
           update_current_connection: nil,
           driver_props: props)
  end

  let(:plugin_manager) { double('plugin_manager', connect: new_connection) }
  let(:retry_util) { double('retry_util') }

  let(:service_container) do
    AwsRubyDriverWrapper::Services::ServiceContainer.new(
      connection_service,
      dialect_service,
      nil,
      host_service,
      plugin_manager,
      session_state_service,
      nil,
      nil
    )
  end

  let(:props) { Concurrent::Map.new }
  let(:plugin) { described_class.new(service_container, props) }

  before do
    allow(AwsRubyDriverWrapper::Utils::RetryUtil).to receive(:new).and_return(retry_util)
  end

  # Runs the (private) mode initialization that normally happens on the first connect.
  def init
    plugin.send(:init_failover_mode)
  end

  describe 'mode initialization' do
    it 'derives the home region from a region-bearing initial endpoint' do
      init
      expect(plugin.instance_variable_get(:@home_region)).to eq('us-east-1')
    end

    it 'prefers an explicitly configured home region' do
      props[:failover_home_region] = 'eu-central-1'
      props[:accessible_regions] = 'eu-central-1,us-east-1'
      init
      expect(plugin.instance_variable_get(:@home_region)).to eq('eu-central-1')
    end

    context 'when the initial endpoint carries no region' do
      let(:initial_host) { global_endpoint }

      it 'raises when no home region is configured' do
        expect { init }.to raise_error(errors::AwsError, /Unable to determine region from endpoint/)
      end

      it 'uses the configured home region' do
        props[:failover_home_region] = 'us-east-1'
        init
        expect(plugin.instance_variable_get(:@home_region)).to eq('us-east-1')
      end
    end

    it 'raises when the home region is not in the accessible regions' do
      props[:accessible_regions] = 'us-west-2,eu-west-1'
      expect { init }.to raise_error(errors::AwsError, /Home region 'us-east-1' is not included/)
    end

    it 'accepts a home region present in the accessible regions' do
      props[:accessible_regions] = 'US-EAST-1, us-west-2'
      init
      expect(plugin.instance_variable_get(:@accessible_regions)).to contain_exactly('us-east-1', 'us-west-2')
    end

    it 'leaves accessible regions unset when the property is absent' do
      init
      expect(plugin.instance_variable_get(:@accessible_regions)).to be_nil
    end

    context 'with a writer cluster endpoint' do
      let(:initial_host) { host_info('mycluster.cluster-xyz.us-east-1.rds.amazonaws.com', host_role::WRITER) }

      it 'defaults both modes to strict_writer' do
        init
        expect(plugin.instance_variable_get(:@in_home_failover_mode)).to eq(mode::STRICT_WRITER)
        expect(plugin.instance_variable_get(:@out_of_home_failover_mode)).to eq(mode::STRICT_WRITER)
      end
    end

    it 'defaults both modes to home_reader_or_writer for an instance endpoint' do
      init
      expect(plugin.instance_variable_get(:@in_home_failover_mode)).to eq(mode::HOME_READER_OR_WRITER)
      expect(plugin.instance_variable_get(:@out_of_home_failover_mode)).to eq(mode::HOME_READER_OR_WRITER)
    end

    context 'with a global writer cluster endpoint' do
      let(:initial_host) { global_endpoint }

      it 'defaults both modes to strict_writer' do
        props[:failover_home_region] = 'us-east-1'
        init
        expect(plugin.instance_variable_get(:@in_home_failover_mode)).to eq(mode::STRICT_WRITER)
        expect(plugin.instance_variable_get(:@out_of_home_failover_mode)).to eq(mode::STRICT_WRITER)
      end
    end

    context 'with a reader cluster endpoint' do
      let(:initial_host) { host_info('mycluster.cluster-ro-xyz.us-east-1.rds.amazonaws.com', host_role::READER) }

      it 'defaults both modes to home_reader_or_writer' do
        init
        expect(plugin.instance_variable_get(:@in_home_failover_mode)).to eq(mode::HOME_READER_OR_WRITER)
        expect(plugin.instance_variable_get(:@out_of_home_failover_mode)).to eq(mode::HOME_READER_OR_WRITER)
      end
    end

    it 'honors explicitly configured modes' do
      props[:in_home_failover_mode] = 'strict_home_reader'
      props[:out_of_home_failover_mode] = 'any_reader_or_writer'
      init
      expect(plugin.instance_variable_get(:@in_home_failover_mode)).to eq(mode::STRICT_HOME_READER)
      expect(plugin.instance_variable_get(:@out_of_home_failover_mode)).to eq(mode::ANY_READER_OR_WRITER)
    end

    it 'raises for an invalid configured mode' do
      props[:in_home_failover_mode] = 'strict_nonsense'
      expect { init }.to raise_error(ArgumentError, /Invalid global database failover mode/)
    end

    context 'with an RDS Proxy endpoint' do
      let(:initial_host) { host_info('myproxy.proxy-xyz.us-east-1.rds.amazonaws.com', host_role::WRITER) }

      it 'raises, since RDS Proxy handles failover internally' do
        expect { init }.to raise_error(errors::AwsError, /not compatible with RDS Proxy endpoints/)
      end
    end

    it 'only initializes once' do
      init
      props[:failover_home_region] = 'eu-west-1'
      init
      expect(plugin.instance_variable_get(:@home_region)).to eq('us-east-1')
    end
  end

  describe '#failover_on_read_only_error?' do
    context 'when both modes are strict_writer' do
      before do
        props[:in_home_failover_mode] = 'strict_writer'
        props[:out_of_home_failover_mode] = 'strict_writer'
        init
      end

      it 'triggers failover regardless of where the primary is' do
        expect(plugin.send(:failover_on_read_only_error?)).to be true
      end

      it 'does not log, since the region of the primary does not matter' do
        expect(plugin.send(:logger)).not_to receive(:debug)
        plugin.send(:failover_on_read_only_error?)
      end
    end

    context 'when neither mode is strict_writer' do
      before do
        props[:in_home_failover_mode] = 'strict_any_reader'
        props[:out_of_home_failover_mode] = 'home_reader_or_writer'
        init
      end

      it 'does not trigger failover regardless of where the primary is' do
        expect(plugin.send(:failover_on_read_only_error?)).to be false
      end

      it 'does not log, since the region of the primary does not matter' do
        expect(plugin.send(:logger)).not_to receive(:debug)
        plugin.send(:failover_on_read_only_error?)
      end
    end

    context 'when only the in-home mode is strict_writer' do
      before do
        props[:in_home_failover_mode] = 'strict_writer'
        props[:out_of_home_failover_mode] = 'strict_any_reader'
        init
      end

      it 'assumes strict_writer and triggers failover' do
        expect(plugin.send(:failover_on_read_only_error?)).to be true
      end

      it 'logs the assumption and its outcome' do
        expect(plugin.send(:logger)).to receive(:debug) do |&message|
          expect(message.call).to include('driver failover will be triggered')
        end
        plugin.send(:failover_on_read_only_error?)
      end

      it 'ignores the topology and the host that is currently connected to' do
        # The primary in the latest known topology may be stale, and a read-only error means the
        # current connection is a reader, so neither region says where the new primary is.
        allow(host_service).to receive(:all_hosts).and_return([remote_writer, remote_reader])
        allow(connection_service).to receive(:current_host_info).and_return(remote_reader)
        expect(plugin.send(:failover_on_read_only_error?)).to be true
      end
    end

    context 'when only the out-of-home mode is strict_writer' do
      before do
        props[:in_home_failover_mode] = 'strict_any_reader'
        props[:out_of_home_failover_mode] = 'strict_writer'
        init
      end

      it 'assumes strict_writer and triggers failover' do
        expect(plugin.send(:failover_on_read_only_error?)).to be true
      end

      it 'logs the assumption and its outcome' do
        expect(plugin.send(:logger)).to receive(:debug) do |&message|
          expect(message.call).to include('driver failover will be triggered')
        end
        plugin.send(:failover_on_read_only_error?)
      end
    end
  end

  describe '#accessible_region?' do
    it 'accepts every host when no restriction is configured' do
      init
      expect(plugin.send(:accessible_region?, remote_reader)).to be true
      expect(plugin.send(:accessible_region?, regionless_reader)).to be true
    end

    context 'when accessible regions are configured' do
      before do
        props[:accessible_regions] = 'us-east-1'
        init
      end

      it 'accepts hosts in an accessible region' do
        expect(plugin.send(:accessible_region?, home_reader)).to be true
      end

      it 'rejects hosts outside the accessible regions' do
        expect(plugin.send(:accessible_region?, remote_reader)).to be false
      end

      it 'rejects hosts whose region cannot be determined' do
        expect(plugin.send(:accessible_region?, regionless_reader)).to be false
      end
    end
  end

  describe '#allowed_hosts_for' do
    let(:topology) { [home_writer, home_reader, remote_writer, remote_reader, regionless_reader] }
    let(:accessible_regions) { nil }

    before do
      props[:accessible_regions] = accessible_regions if accessible_regions
      init
    end

    it 'selects only home-region readers for strict_home_reader' do
      expect(plugin.send(:allowed_hosts_for, mode::STRICT_HOME_READER, topology)).to contain_exactly(home_reader)
    end

    it 'selects only out-of-home readers for strict_out_of_home_reader' do
      expect(plugin.send(:allowed_hosts_for, mode::STRICT_OUT_OF_HOME_READER, topology)).to contain_exactly(remote_reader)
    end

    it 'selects readers in any region for strict_any_reader' do
      expect(plugin.send(:allowed_hosts_for, mode::STRICT_ANY_READER, topology))
        .to contain_exactly(home_reader, remote_reader, regionless_reader)
    end

    it 'selects writers and home-region readers for home_reader_or_writer' do
      expect(plugin.send(:allowed_hosts_for, mode::HOME_READER_OR_WRITER, topology))
        .to contain_exactly(home_writer, remote_writer, home_reader)
    end

    it 'selects writers and out-of-home readers for out_of_home_reader_or_writer' do
      expect(plugin.send(:allowed_hosts_for, mode::OUT_OF_HOME_READER_OR_WRITER, topology))
        .to contain_exactly(home_writer, remote_writer, remote_reader)
    end

    it 'selects every host for any_reader_or_writer' do
      expect(plugin.send(:allowed_hosts_for, mode::ANY_READER_OR_WRITER, topology)).to match_array(topology)
    end

    context 'when accessible regions are configured' do
      let(:accessible_regions) { 'us-east-1' }

      it 'filters out hosts in inaccessible regions' do
        expect(plugin.send(:allowed_hosts_for, mode::ANY_READER_OR_WRITER, topology))
          .to contain_exactly(home_writer, home_reader)
      end

      it 'yields no candidates for a mode that only allows inaccessible hosts' do
        expect(plugin.send(:allowed_hosts_for, mode::STRICT_OUT_OF_HOME_READER, topology)).to be_empty
      end
    end

    context 'when the region of a host cannot be determined' do
      let(:topology) { [regionless_reader] }

      it 'excludes the host from the modes that place a region requirement on it' do
        [mode::STRICT_HOME_READER, mode::STRICT_OUT_OF_HOME_READER,
         mode::HOME_READER_OR_WRITER, mode::OUT_OF_HOME_READER_OR_WRITER].each do |m|
          expect(plugin.send(:allowed_hosts_for, m, topology)).to be_empty
        end
      end

      it 'still includes the host for the modes that ignore regions' do
        [mode::STRICT_ANY_READER, mode::ANY_READER_OR_WRITER].each do |m|
          expect(plugin.send(:allowed_hosts_for, m, topology)).to contain_exactly(regionless_reader)
        end
      end

      it 'logs the host that was skipped' do
        expect(plugin.send(:logger)).to receive(:debug) do |&message|
          expect(message.call).to include(regionless_reader.host, 'will not be considered an allowed host')
        end
        plugin.send(:allowed_hosts_for, mode::STRICT_HOME_READER, topology)
      end

      it 'only logs the host once, since it is called on every failover retry' do
        expect(plugin.send(:logger)).to receive(:debug).once
        3.times { plugin.send(:allowed_hosts_for, mode::STRICT_HOME_READER, topology) }
      end

      it 'does not log for the modes that ignore regions' do
        expect(plugin.send(:logger)).not_to receive(:debug)
        plugin.send(:allowed_hosts_for, mode::STRICT_ANY_READER, topology)
      end
    end
  end

  describe '#verify_role_for' do
    before { init }

    it 'requires a reader for the strict reader modes' do
      [mode::STRICT_HOME_READER, mode::STRICT_OUT_OF_HOME_READER, mode::STRICT_ANY_READER].each do |m|
        expect(plugin.send(:verify_role_for, m)).to eq(host_role::READER)
      end
    end

    it 'requires no particular role for the reader_or_writer modes' do
      [mode::HOME_READER_OR_WRITER, mode::OUT_OF_HOME_READER_OR_WRITER, mode::ANY_READER_OR_WRITER].each do |m|
        expect(plugin.send(:verify_role_for, m)).to be_nil
      end
    end
  end

  describe '#failover' do
    let(:result) { AwsRubyDriverWrapper::Utils::RetryUtil::Result.new(new_connection, home_writer) }

    context 'in strict_writer mode' do
      before do
        props[:in_home_failover_mode] = 'strict_writer'
        props[:out_of_home_failover_mode] = 'strict_writer'
        init
      end

      it 'connects to the writer and reports failover success' do
        expect(retry_util).to receive(:connect_to_writer).and_return(result)
        expect(connection_service).to receive(:update_current_connection).with(new_connection, home_writer)
        expect { plugin.send(:failover) }.to raise_error(errors::FailoverSuccessError)
      end

      it 'raises when the topology cannot be refreshed' do
        allow(host_service).to receive(:force_refresh_host_list?).and_return(false)
        expect { plugin.send(:failover) }.to raise_error(errors::FailoverFailedError, /discover the new topology/)
      end

      it 'raises when the topology has no writer' do
        allow(host_service).to receive(:all_hosts).and_return([home_reader, remote_reader])
        expect { plugin.send(:failover) }.to raise_error(errors::FailoverFailedError, /Unable to find a writer/)
      end

      it 'raises when connecting to the writer times out' do
        allow(retry_util).to receive(:connect_to_writer).and_raise(Timeout::Error)
        expect { plugin.send(:failover) }.to raise_error(errors::FailoverFailedError, /Unable to connect to the new writer/)
      end

      it 'raises TransactionStateUnknownError when a transaction was open' do
        allow(session_state_service).to receive(:in_transaction?).and_return(true)
        allow(retry_util).to receive(:connect_to_writer).and_return(result)
        expect { plugin.send(:failover) }.to raise_error(errors::TransactionStateUnknownError)
      end
    end

    context 'when the new writer is in an inaccessible region' do
      let(:topology) { [remote_writer, home_reader] }

      before do
        props[:accessible_regions] = 'us-east-1'
        props[:in_home_failover_mode] = 'strict_writer'
        props[:out_of_home_failover_mode] = 'strict_writer'
        init
      end

      it 'fails without attempting a connection' do
        expect(retry_util).not_to receive(:connect_to_writer)
        expect { plugin.send(:failover) }
          .to raise_error(errors::FailoverFailedError, /Writer is in region 'us-west-2' which is not in the list/)
      end
    end

    context 'when the primary is in the home region' do
      let(:topology) { [home_writer, home_reader, remote_reader] }

      before do
        props[:in_home_failover_mode] = 'strict_home_reader'
        props[:out_of_home_failover_mode] = 'strict_out_of_home_reader'
        init
      end

      it 'applies the active-home mode' do
        expect(retry_util).to receive(:connect_to_allowed_host)
          .with(plugin, plugin_manager, hash_including(verify_role: host_role::READER)) do |*, &candidates|
            expect(candidates.call(topology)).to contain_exactly(home_reader)
            result
          end
        expect { plugin.send(:failover) }.to raise_error(errors::FailoverSuccessError)
      end
    end

    context 'when the primary is outside the home region' do
      let(:topology) { [remote_writer, home_reader, remote_reader] }

      before do
        props[:in_home_failover_mode] = 'strict_home_reader'
        props[:out_of_home_failover_mode] = 'strict_out_of_home_reader'
        init
      end

      it 'applies the inactive-home mode' do
        expect(retry_util).to receive(:connect_to_allowed_host)
          .with(plugin, plugin_manager, hash_including(verify_role: host_role::READER)) do |*, &candidates|
            expect(candidates.call(topology)).to contain_exactly(remote_reader)
            result
          end
        expect { plugin.send(:failover) }.to raise_error(errors::FailoverSuccessError)
      end

      it 'raises when no allowed host can be connected to before the deadline' do
        allow(retry_util).to receive(:connect_to_allowed_host).and_raise(Timeout::Error)
        expect { plugin.send(:failover) }
          .to raise_error(errors::FailoverFailedError, /Unable to connect to a host allowed by failover mode/)
      end
    end

    context 'when the region of the new primary cannot be determined' do
      let(:regionless_writer) { host_info('writer-3.example.com', host_role::WRITER) }
      let(:topology) { [regionless_writer, home_reader, remote_reader] }

      before do
        props[:in_home_failover_mode] = 'strict_home_reader'
        props[:out_of_home_failover_mode] = 'strict_out_of_home_reader'
        init
      end

      it 'applies the in-home mode, since the primary usually stays in the region it was in' do
        expect(retry_util).to receive(:connect_to_allowed_host)
          .with(plugin, plugin_manager, hash_including(verify_role: host_role::READER)) do |*, &candidates|
            expect(candidates.call(topology)).to contain_exactly(home_reader)
            result
          end
        expect { plugin.send(:failover) }.to raise_error(errors::FailoverSuccessError)
      end

      it 'warns, since a GDB topology host is expected to carry a region' do
        allow(retry_util).to receive(:connect_to_allowed_host).and_return(result)
        expect(plugin.send(:logger)).to receive(:warn) do |&message|
          expect(message.call).to include(regionless_writer.host, 'strict_home_reader')
        end
        expect { plugin.send(:failover) }.to raise_error(errors::FailoverSuccessError)
      end
    end

    it 'is skipped when the connection was explicitly closed' do
      init
      plugin.execute(AwsRubyDriverWrapper::RubyMethod::CONNECTION_CLOSE.name, -> { :closed })
      expect(host_service).not_to receive(:force_refresh_host_list?)
      expect(plugin.send(:failover)).to be_nil
    end
  end

  describe 'unsupported inherited failover paths' do
    it 'raises for failover_reader' do
      expect { plugin.send(:failover_reader) }.to raise_error(NotImplementedError)
    end

    it 'raises for failover_writer' do
      expect { plugin.send(:failover_writer) }.to raise_error(NotImplementedError)
    end
  end
end
