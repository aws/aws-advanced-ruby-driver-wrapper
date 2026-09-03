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
require 'aws_advanced_ruby_driver_wrapper/plugins/kms_encryption/connection_source'

RSpec.describe AwsAdvancedRubyDriverWrapper::Plugins::Encryption::ConnectionSource do
  let(:host) { double('HostInfo') }
  let(:driver_props) { { connect_timeout: 3 } }
  let(:wrapper_props) { double('WrapperProps') }
  let(:dialect) { double('DriverDialect') }
  let(:connection_service) do
    double('ConnectionService', current_host_info: host, driver_props: driver_props, wrapper_props: wrapper_props)
  end
  let(:plugin_manager) { double('PluginManager') }
  let(:dialect_service) { double('DialectService', driver_dialect: dialect) }
  let(:service_container) do
    double('ServiceContainer', connection_service: connection_service, plugin_manager: plugin_manager,
                               dialect_service: dialect_service)
  end

  # A minimal host that just mixes in the module, the way KeyManager/MetadataManager do.
  let(:klass) do
    Class.new do
      include AwsAdvancedRubyDriverWrapper::Plugins::Encryption::ConnectionSource

      def initialize(**kwargs)
        use_connection_source(**kwargs)
      end
    end
  end

  describe '#use_connection_source' do
    it 'requires exactly one source (neither)' do
      expect { klass.new(connection: nil, service_container: nil) }
        .to raise_error(ArgumentError, /exactly one/)
    end

    it 'requires exactly one source (both)' do
      expect { klass.new(connection: double('Conn'), service_container: service_container) }
        .to raise_error(ArgumentError, /exactly one/)
    end
  end

  describe '#with_connection with a supplied connection' do
    let(:connection) { double('Connection') }
    subject(:source) { klass.new(connection: connection, service_container: nil) }

    it 'yields the supplied connection' do
      expect { |b| source.with_connection(&b) }.to yield_with_args(connection)
    end

    it 'returns the block result' do
      expect(source.with_connection { |_c| 42 }).to eq(42)
    end

    it 'never closes it (a plain double would raise if #close were called)' do
      expect(connection).not_to receive(:close)
      2.times { expect(source.with_connection { |c| c }).to be(connection) }
    end
  end

  describe '#with_connection with a service container' do
    let(:opened) { double('OpenedConnection') }
    subject(:source) { klass.new(connection: nil, service_container: service_container) }

    before do
      allow(plugin_manager).to receive(:internal_connect).and_return(opened)
      allow(dialect).to receive(:close_connection)
    end

    it 'opens a short-lived connection through the connect pipeline and yields it' do
      expect { |b| source.with_connection(operation: 'X', &b) }.to yield_with_args(opened)
      expect(plugin_manager).to have_received(:internal_connect).with(host, driver_props, wrapper_props, false)
    end

    it 'closes the opened connection afterward' do
      source.with_connection { |c| c }
      expect(dialect).to have_received(:close_connection).with(opened)
    end

    it 'closes the connection even when the block raises' do
      expect { source.with_connection { raise 'boom' } }.to raise_error('boom')
      expect(dialect).to have_received(:close_connection).with(opened)
    end

    it 'raises when the connect pipeline returns no connection' do
      allow(plugin_manager).to receive(:internal_connect).and_return(nil)
      expect { source.with_connection(operation: 'LOAD') { |c| c } }
        .to raise_error(AwsAdvancedRubyDriverWrapper::Errors::AwsError, /no connection/)
    end
  end
end
