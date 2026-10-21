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
require 'aws_advanced_ruby_driver_wrapper/mysql'
require 'aws_advanced_ruby_driver_wrapper/postgresql'

RSpec.describe 'Telemetry of client initialization' do
  include TelemetryHelper

  let(:plugin_manager) { double('PluginManager', connect: :connection) }
  let(:connection_service) { double('ConnectionService', initial_host_info: nil, driver_props: {}) }
  let(:container) do
    AwsAdvancedRubyDriverWrapper::Services::ServiceContainer.new(
      connection_service:, plugin_manager:, host_service: double('HostService', refresh_host_list: nil)
    )
  end

  before do
    allow(AwsAdvancedRubyDriverWrapper::Services::ServiceUtility).to receive(:create_standard_container) do |_config, telemetry_factory:|
      container.telemetry_factory = telemetry_factory
      container
    end
  end

  {
    AwsAdvancedRubyDriverWrapper::WrapperMysql2Client => ->(**props) { { host: 'db.example.com', username: 'user', **props } },
    AwsAdvancedRubyDriverWrapper::WrapperPgConnection => ->(**props) { { host: 'db.example.com', user: 'user', **props } }
  }.each do |client_class, connect_args|
    describe client_class do
      let(:span_name) { "#{client_class.name}.new" }

      it 'records the initialization as a top-level span' do
        client_class.new(**connect_args.call(**telemetry_props(telemetry_submit_top_level: true)))

        span = span_named(span_name)
        expect(span.parent_span_id).to eq(OpenTelemetry::Trace::INVALID_SPAN_ID)
        expect(span.status.code).to eq(OpenTelemetry::Trace::Status::OK)
      end

      it 'records the error the initialization failed with' do
        allow(plugin_manager).to receive(:connect).and_raise(IOError, 'connection refused')

        expect { client_class.new(**connect_args.call(**telemetry_props(telemetry_submit_top_level: true))) }
          .to raise_error(IOError)

        span = span_named(span_name)
        expect(span.status.code).to eq(OpenTelemetry::Trace::Status::ERROR)
        expect(span.attributes).to include('exception_type' => 'IOError', 'exception_message' => 'connection refused')
      end

      it 'records the connection with the same telemetry factory the connection uses afterwards' do
        client_class.new(**connect_args.call(**telemetry_props))

        expect(container.telemetry_factory).to be_a(AwsAdvancedRubyDriverWrapper::Utils::Telemetry::TelemetryFactory)
        expect(container.telemetry_factory.in_use?).to be(true)
      end

      it 'records nothing when telemetry is not enabled' do
        client_class.new(**connect_args.call)

        expect(finished_spans).to be_empty
      end
    end
  end
end
