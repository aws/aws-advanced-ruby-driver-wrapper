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
require 'aws_ruby_database_driver_wrapper/utils/retry_util'
require 'aws_ruby_database_driver_wrapper/host/host_info'
require 'aws_ruby_database_driver_wrapper/host/host_role'
require 'aws_ruby_database_driver_wrapper/host/host_availability'

RSpec.describe AwsRubyDatabaseDriverWrapper::Utils::RetryUtil do
  let(:host_role) { AwsRubyDatabaseDriverWrapper::Host::HostRole }
  let(:host_availability) { AwsRubyDatabaseDriverWrapper::Host::HostAvailability }

  let(:writer_host) do
    AwsRubyDatabaseDriverWrapper::Host::HostInfo.new(
      host: 'writer-instance.xyz.us-east-1.rds.amazonaws.com',
      port: '5432',
      role: host_role::WRITER
    )
  end

  let(:reader_host) do
    AwsRubyDatabaseDriverWrapper::Host::HostInfo.new(
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

  let(:host_service) do
    double('host_service',
           all_hosts: [writer_host, reader_host],
           hosts: [writer_host, reader_host],
           refresh_host_list: nil)
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

      it 'returns a WriterResult with the connection and host info' do
        deadline = Time.now + 5
        result = retry_util.connect_to_writer(plugin_to_skip, plugin_manager, deadline: deadline)

        expect(result).to be_a(described_class::WriterResult)
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
end
