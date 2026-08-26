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

require_relative '../spec_helper'
require 'aws_ruby_driver_wrapper/utils/retry_util'
require 'aws_ruby_driver_wrapper/host/host_info'
require 'aws_ruby_driver_wrapper/host/host_role'
require 'aws_ruby_driver_wrapper/host/host_availability'
require 'aws_ruby_driver_wrapper/host/random_host_selector'

RSpec.describe AwsRubyDriverWrapper::Utils::RetryUtil do
  let(:host_role) { AwsRubyDriverWrapper::Host::HostRole }
  let(:host_availability) { AwsRubyDriverWrapper::Host::HostAvailability }

  let(:writer_host) do
    AwsRubyDriverWrapper::Host::HostInfo.new(
      host: 'writer-instance.xyz.us-east-1.rds.amazonaws.com',
      port: '5432',
      role: host_role::WRITER
    )
  end

  let(:reader_host) do
    AwsRubyDriverWrapper::Host::HostInfo.new(
      host: 'reader-instance.xyz.us-east-1.rds.amazonaws.com',
      port: '5432',
      role: host_role::READER
    )
  end

  let(:connection) { double('connection', close: nil) }
  let(:plugin_to_skip) { double('plugin') }
  let(:props) { Concurrent::Map.new }

  let(:db_dialect) { double('db_dialect') }
  let(:driver_dialect) { double('driver_dialect', close_connection: nil) }
  let(:dialect_service) { double('dialect_service', db_dialect: db_dialect, driver_dialect: driver_dialect) }
  let(:plugin_manager) { double('plugin_manager') }

  # RetryUtil delegates candidate selection to the host service, which applies the configured
  # strategy. The real selector picks from the candidates it is given, so mirror that here.
  let(:host_selector) { AwsRubyDriverWrapper::Host::RandomHostSelector.new }

  let(:host_service) do
    double('host_service',
           all_hosts: [writer_host, reader_host],
           hosts: [writer_host, reader_host],
           refresh_host_list: nil)
  end

  before do
    allow(host_service).to receive(:select_host) do |hosts, role, _strategy|
      host_selector.select_host(hosts, role)
    end
  end

  let(:connection_service) { double('connection_service', driver_props: props) }

  let(:service_container) do
    double('service_container',
           host_service: host_service,
           plugin_manager: plugin_manager,
           dialect_service: dialect_service,
           connection_service: connection_service)
  end

  let(:retry_util) { described_class.new(service_container) }

  describe '#connect_to_writer' do
    context 'when writer is available and role is confirmed' do
      before do
        allow(plugin_manager).to receive(:connect).and_return(connection)
        allow(db_dialect).to receive(:host_role).with(connection).and_return(host_role::WRITER)
      end

      it 'returns a Result with the connection and host info' do
        deadline = Time.now + 5
        result = retry_util.connect_to_writer(plugin_to_skip, plugin_manager, deadline: deadline)

        expect(result).to be_a(described_class::Result)
        expect(result.connection).to eq(connection)
        expect(result.host_info.role).to eq(host_role::WRITER)
      end

      it 'connects via the plugin manager, skipping the specified plugin' do
        deadline = Time.now + 5
        expect(plugin_manager).to receive(:connect).with(writer_host, props, false, plugin_to_skip: plugin_to_skip)
        retry_util.connect_to_writer(plugin_to_skip, plugin_manager, deadline: deadline)
      end
    end

    context 'when no writer is in the topology' do
      before do
        allow(host_service).to receive(:all_hosts).and_return([reader_host])
      end

      it 'raises Timeout::Error when deadline expires' do
        deadline = Time.now + 0.01
        expect do
          retry_util.connect_to_writer(plugin_to_skip, plugin_manager, deadline: deadline)
        end.to raise_error(Timeout::Error)
      end
    end

    context 'when writer is not in the allowed hosts' do
      before do
        allow(host_service).to receive(:hosts).and_return([reader_host])
      end

      it 'raises Timeout::Error when deadline expires' do
        deadline = Time.now + 0.01
        expect do
          retry_util.connect_to_writer(plugin_to_skip, plugin_manager, deadline: deadline)
        end.to raise_error(Timeout::Error)
      end
    end

    context 'when connect raises an error' do
      before do
        allow(plugin_manager).to receive(:connect).and_raise(StandardError, 'connection refused')
      end

      it 'retries until timeout and closes any partial connections' do
        deadline = Time.now + 0.15
        expect do
          retry_util.connect_to_writer(plugin_to_skip, plugin_manager, deadline: deadline)
        end.to raise_error(Timeout::Error)
      end
    end

    context 'when connected host is not actually a writer' do
      before do
        allow(plugin_manager).to receive(:connect).and_return(connection)
        allow(db_dialect).to receive(:host_role).with(connection).and_return(host_role::READER)
      end

      it 'closes the connection and retries until timeout' do
        deadline = Time.now + 0.15
        expect(driver_dialect).to receive(:close_connection).with(connection).at_least(:once)
        expect do
          retry_util.connect_to_writer(plugin_to_skip, plugin_manager, deadline: deadline)
        end.to raise_error(Timeout::Error)
      end
    end

    context 'when deadline has already passed' do
      it 'raises Timeout::Error immediately' do
        deadline = Time.now - 1
        expect do
          retry_util.connect_to_writer(plugin_to_skip, plugin_manager, deadline: deadline)
        end.to raise_error(Timeout::Error)
      end
    end

    context 'when writer becomes available after a retry' do
      let(:call_count) { [0] }

      before do
        allow(host_service).to receive(:all_hosts) do
          call_count[0] += 1
          if call_count[0] <= 2
            [reader_host]
          else
            [writer_host, reader_host]
          end
        end
        allow(plugin_manager).to receive(:connect).and_return(connection)
        allow(db_dialect).to receive(:host_role).with(connection).and_return(host_role::WRITER)
      end

      it 'eventually connects to the writer' do
        deadline = Time.now + 5
        result = retry_util.connect_to_writer(plugin_to_skip, plugin_manager, deadline: deadline)
        expect(result.connection).to eq(connection)
      end
    end
  end

  describe '#connect_to_allowed_host' do
    before do
      allow(plugin_manager).to receive(:connect).and_return(connection)
      allow(db_dialect).to receive(:host_role).with(connection).and_return(host_role::READER)
    end

    it 'connects to a host yielded by the block' do
      result = retry_util.connect_to_allowed_host(plugin_to_skip, plugin_manager,
                                                  verify_role: host_role::READER,
                                                  deadline: Time.now + 5) { [reader_host] }

      expect(result).to be_a(described_class::Result)
      expect(result.connection).to eq(connection)
      expect(result.host_info.host).to eq(reader_host.host)
      expect(result.host_info.role).to eq(host_role::READER)
    end

    it 'passes the current allowed hosts to the block' do
      yielded = nil
      retry_util.connect_to_allowed_host(plugin_to_skip, plugin_manager,
                                         verify_role: host_role::READER,
                                         deadline: Time.now + 5) do |allowed_hosts|
        yielded = allowed_hosts
        [reader_host]
      end

      expect(yielded).to eq([writer_host, reader_host])
    end

    it 'skips role verification when verify_role is nil' do
      expect(db_dialect).not_to receive(:host_role)
      result = retry_util.connect_to_allowed_host(plugin_to_skip, plugin_manager,
                                                  deadline: Time.now + 5) { [writer_host] }
      expect(result.connection).to eq(connection)
    end

    it 'uses the requested selection strategy' do
      expect(host_service).to receive(:select_host).with(anything, host_role::READER, 'some_strategy').and_return(reader_host)
      retry_util.connect_to_allowed_host(plugin_to_skip, plugin_manager,
                                         verify_role: host_role::READER,
                                         strategy: 'some_strategy',
                                         deadline: Time.now + 5) { [reader_host] }
    end

    it 'defaults to the random strategy when none is given' do
      expect(host_service).to receive(:select_host).with(anything, host_role::READER, 'random').and_return(reader_host)
      retry_util.connect_to_allowed_host(plugin_to_skip, plugin_manager,
                                         verify_role: host_role::READER,
                                         deadline: Time.now + 5) { [reader_host] }
    end

    it 'marks candidates available so that unavailable hosts are still considered' do
      unavailable = reader_host.deep_dup.tap { |h| h.availability = host_availability::UNAVAILABLE }
      result = retry_util.connect_to_allowed_host(plugin_to_skip, plugin_manager,
                                                  verify_role: host_role::READER,
                                                  deadline: Time.now + 5) { [unavailable] }
      expect(result.connection).to eq(connection)
    end

    it 'retries when the block yields no candidates, then succeeds' do
      calls = 0
      result = retry_util.connect_to_allowed_host(plugin_to_skip, plugin_manager,
                                                  verify_role: host_role::READER,
                                                  deadline: Time.now + 5) do
        calls += 1
        calls < 3 ? [] : [reader_host]
      end

      expect(calls).to eq(3)
      expect(result.connection).to eq(connection)
    end

    it 'times out when the block never yields a candidate' do
      expect do
        retry_util.connect_to_allowed_host(plugin_to_skip, plugin_manager,
                                           verify_role: host_role::READER,
                                           deadline: Time.now + 0.15) { [] }
      end.to raise_error(Timeout::Error)
    end

    it 'closes the connection and moves on when the role does not match' do
      allow(db_dialect).to receive(:host_role).with(connection).and_return(host_role::WRITER)
      expect(driver_dialect).to receive(:close_connection).with(connection).at_least(:once)

      expect do
        retry_util.connect_to_allowed_host(plugin_to_skip, plugin_manager,
                                           verify_role: host_role::READER,
                                           deadline: Time.now + 0.15) { [reader_host] }
      end.to raise_error(Timeout::Error)
    end

    it 'tries the next candidate when a connection attempt raises' do
      allow(plugin_manager).to receive(:connect) do |host, *|
        raise StandardError, 'connection refused' if host.host == writer_host.host

        connection
      end

      result = retry_util.connect_to_allowed_host(plugin_to_skip, plugin_manager,
                                                  deadline: Time.now + 5) { [writer_host, reader_host] }
      expect(result.host_info.host).to eq(reader_host.host)
    end

    it 'raises Timeout::Error immediately when the deadline has passed' do
      expect do
        retry_util.connect_to_allowed_host(plugin_to_skip, plugin_manager, deadline: Time.now - 1) { [reader_host] }
      end.to raise_error(Timeout::Error)
    end
  end
end
