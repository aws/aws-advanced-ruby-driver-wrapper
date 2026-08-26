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
require 'aws_ruby_driver_wrapper/services/connection_service'
require 'aws_ruby_driver_wrapper/host/host_info'
require 'aws_ruby_driver_wrapper/host/host_role'
require 'aws_ruby_driver_wrapper/errors'

RSpec.describe AwsRubyDriverWrapper::Services::ConnectionService do
  let(:writer_host) do
    AwsRubyDriverWrapper::Host::HostInfo.new(
      host: 'writer-host',
      port: 5432,
      role: AwsRubyDriverWrapper::Host::HostRole::WRITER
    )
  end

  let(:reader_host) do
    AwsRubyDriverWrapper::Host::HostInfo.new(
      host: 'reader-host',
      port: 5432,
      role: AwsRubyDriverWrapper::Host::HostRole::READER
    )
  end

  let(:host_service) do
    instance_double('HostService', all_hosts: [writer_host, reader_host], hosts: [writer_host, reader_host])
  end

  let(:session_state_service) do
    instance_double('SessionStateService', reset: nil)
  end

  let(:service_container) do
    instance_double('ServiceContainer', host_service: host_service, session_state_service: session_state_service)
  end

  let(:config) do
    instance_double('ConnectionConfig',
                    driver_name: :postgresql, wrapper_props: {}, driver_props: { host: 'writer-host' }, initial_host_info: nil)
  end

  let(:service) { described_class.new(service_container, config) }

  describe '#current_host_info' do
    context 'when initial_host_info is set' do
      let(:config) do
        instance_double('ConnectionConfig',
                        driver_name: :postgresql, wrapper_props: {}, driver_props: { host: 'writer-host' }, initial_host_info: writer_host)
      end

      it 'returns the initial host info' do
        expect(service.current_host_info).to eq(writer_host)
      end
    end

    context 'when initial_host_info is nil' do
      before do
        allow(AwsRubyDriverWrapper::Utils::HostListUtils).to receive(:writer).and_return(writer_host)
        allow(AwsRubyDriverWrapper::Utils::HostListUtils).to receive(:contains_url?).and_return(true)
      end

      it 'resolves the writer from the host list' do
        expect(service.current_host_info).to eq(writer_host)
      end
    end

    context 'when the host list is empty' do
      let(:host_service) { instance_double('HostService', all_hosts: [], hosts: []) }

      it 'raises an error' do
        expect { service.current_host_info }
          .to raise_error(AwsRubyDriverWrapper::Errors::AwsError, /host list is empty/)
      end
    end

    context 'when there is no writer but hosts exist' do
      let(:host_service) do
        instance_double('HostService', all_hosts: [reader_host], hosts: [reader_host])
      end

      before do
        allow(AwsRubyDriverWrapper::Utils::HostListUtils).to receive(:writer).and_return(nil)
      end

      it 'falls back to the first host in the list' do
        expect(service.current_host_info).to eq(reader_host)
      end
    end

    context 'when the writer is not in the allowed hosts list' do
      let(:host_service) do
        instance_double('HostService', all_hosts: [writer_host, reader_host], hosts: [reader_host])
      end

      before do
        allow(AwsRubyDriverWrapper::Utils::HostListUtils).to receive(:writer).and_return(writer_host)
        allow(AwsRubyDriverWrapper::Utils::HostListUtils).to receive(:contains_url?).and_return(false)
      end

      it 'raises an error' do
        expect { service.current_host_info }
          .to raise_error(AwsRubyDriverWrapper::Errors::AwsError, /not in the list of allowed hosts/)
      end
    end
  end

  describe '#update_current_connection' do
    it 'updates the current connection and host info' do
      connection = instance_double('Connection')
      service.update_current_connection(connection, reader_host)

      expect(service.current_connection).to eq(connection)
      expect(service.current_host_info).to eq(reader_host)
    end

    context 'when replacing an existing connection' do
      let(:driver_dialect) { instance_double('DriverDialect', close_connection: nil) }
      let(:dialect_service) { instance_double('DialectService', driver_dialect: driver_dialect) }
      let(:service_container) do
        instance_double('ServiceContainer',
                        host_service: host_service,
                        session_state_service: session_state_service,
                        dialect_service: dialect_service)
      end

      it 'closes the previous connection so it does not leak' do
        old_connection = instance_double('Connection')
        new_connection = instance_double('Connection')
        service.update_current_connection(old_connection, writer_host)

        expect(driver_dialect).to receive(:close_connection).with(old_connection)
        service.update_current_connection(new_connection, reader_host)
        expect(service.current_connection).to eq(new_connection)
      end

      it 'does not close the connection when it is the same object' do
        connection = instance_double('Connection')
        service.update_current_connection(connection, writer_host)

        expect(driver_dialect).not_to receive(:close_connection)
        service.update_current_connection(connection, reader_host)
      end
    end
  end

  describe '#driver_name' do
    it 'returns the driver name from the config' do
      expect(service.driver_name).to eq(:postgresql)
    end
  end

  describe '#wrapper_props' do
    it 'returns wrapper properties from the config' do
      expect(service.wrapper_props).to eq({})
    end
  end

  describe '#driver_props' do
    it 'returns driver properties from the config' do
      expect(service.driver_props).to eq({ host: 'writer-host' })
    end
  end

  describe '#multi_host_url?' do
    context 'when the host contains a comma' do
      let(:config) do
        instance_double('ConnectionConfig',
                        driver_name: :postgresql, wrapper_props: {}, driver_props: { host: 'host1,host2' },
                        initial_host_info: nil, multi_host_url?: true)
      end

      it 'returns true' do
        expect(service.multi_host_url?).to be true
      end
    end

    context 'when the host does not contain a comma' do
      it 'returns false' do
        allow(config).to receive(:multi_host_url?).and_return(false)
        expect(service.multi_host_url?).to be false
      end
    end
  end

  describe '#pg?' do
    context 'when driver is postgresql' do
      it 'returns true' do
        expect(service.pg?).to be true
      end
    end

    context 'when driver is mysql2' do
      let(:config) do
        instance_double('ConnectionConfig',
                        driver_name: :mysql2, wrapper_props: {}, driver_props: { host: 'writer-host' }, initial_host_info: nil)
      end

      it 'returns false' do
        expect(service.pg?).to be false
      end
    end
  end
end
