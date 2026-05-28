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

require 'rspec'
require 'aws_ruby_database_driver_wrapper/services/service_utility'
require 'aws_ruby_database_driver_wrapper/host/host_info'
require 'aws_ruby_database_driver_wrapper'

RSpec.describe AwsRubyDatabaseDriverWrapper::Services::ServiceUtility do
  let(:config) do
    AwsRubyDatabaseDriverWrapper::Utils::ConnectionConfig.new(
      driver_name: :postgresql,
      driver_props: { host: 'myhost', port: 5432 },
      wrapper_props: {},
      initial_host_info: AwsRubyDatabaseDriverWrapper::Host::HostInfo.new(host: 'myhost', port: 5432)
    )
  end

  after { AwsRubyDatabaseDriverWrapper::Services::CoreServices.reset! }

  describe '.create_standard_container' do
    subject(:container) { described_class.create_standard_container(config) }

    it 'returns a ServiceContainer with all services wired' do
      expect(container).to be_a(AwsRubyDatabaseDriverWrapper::Services::ServiceContainer)
      expect(container.connection_service).to be_a(AwsRubyDatabaseDriverWrapper::Services::ConnectionService)
      expect(container.dialect_service).to be_a(AwsRubyDatabaseDriverWrapper::Services::DialectService)
      expect(container.host_service).to be_a(AwsRubyDatabaseDriverWrapper::Services::HostService)
      expect(container.session_state_service).to be_a(AwsRubyDatabaseDriverWrapper::Services::SessionStateService)
      expect(container.plugin_manager).to be_a(AwsRubyDatabaseDriverWrapper::Services::PluginManager)
    end

    it 'passes config to ConnectionService' do
      expect(container.connection_service.driver_name).to eq(:postgresql)
      expect(container.connection_service.config.initial_host_info.host).to eq('myhost')
    end

    it 'resolves the correct driver dialect' do
      expect(container.dialect_service.driver_dialect).to be_a(
        AwsRubyDatabaseDriverWrapper::DriverDialects::PgDriverDialect
      )
    end
  end

  describe '.create_monitor_container' do
    let(:parent) { described_class.create_standard_container(config) }
    subject(:container) { described_class.create_monitor_container(parent) }

    it 'reuses dialect_service from parent' do
      expect(container.dialect_service).to equal(parent.dialect_service)
    end

    it 'reuses host_service from parent' do
      expect(container.host_service).to equal(parent.host_service)
    end

    it 'does not set plugin_manager' do
      expect(container.plugin_manager).to be_nil
    end

    it 'does not set connection_service' do
      expect(container.connection_service).to be_nil
    end

    it 'does not set session_state_service' do
      expect(container.session_state_service).to be_nil
    end
  end
end
