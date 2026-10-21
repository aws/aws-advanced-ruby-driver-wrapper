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
require 'aws_advanced_ruby_driver_wrapper/services/plugin_manager'
require 'aws_advanced_ruby_driver_wrapper/services/service_container'
require 'aws_advanced_ruby_driver_wrapper/plugins/default_plugin'
require 'aws_advanced_ruby_driver_wrapper/utils/telemetry/telemetry_factory'

RSpec.describe 'Telemetry in the plugin pipeline' do
  include TelemetryHelper

  # Records the span that is current while it runs, so a test can tell which span its work was part of.
  telemetry_test_plugin = Class.new do
    attr_reader :subscribed_methods, :current_spans

    def initialize(subscribed_methods = Set['*'])
      @subscribed_methods = subscribed_methods
      @current_spans = []
    end

    def connect(_host_info, _props, _is_initial_connection, next_plugin_callable)
      @current_spans << OpenTelemetry::Trace.current_span
      next_plugin_callable.call
    end

    def internal_connect(_host_info, _props, _wrapper_props, _is_initial_connection, next_plugin_callable)
      next_plugin_callable.call
    end

    def execute(_method_name, next_plugin_callable, ...)
      @current_spans << OpenTelemetry::Trace.current_span
      next_plugin_callable.call(...)
    end
  end

  # The plugin every pipeline ends with. Like the default plugin, it calls the target driver method.
  terminal_plugin = Class.new(telemetry_test_plugin) do
    def connect(_host_info, _props, _is_initial_connection, _next_plugin_callable)
      :connection
    end

    def internal_connect(_host_info, _props, _wrapper_props, _is_initial_connection, _next_plugin_callable)
      :connection
    end

    def execute(_method_name, target_callable, ...)
      target_callable.call(...)
    end
  end

  let(:pm_class) { AwsAdvancedRubyDriverWrapper::Services::PluginManager }
  let(:outer_plugin) { telemetry_test_plugin.new }
  let(:inner_plugin_class) { Class.new(telemetry_test_plugin) }
  let(:inner_plugin) { inner_plugin_class.new }
  let(:base_plugin) { terminal_plugin.new }
  let(:wrapper_props) { telemetry_props(telemetry_submit_top_level: true) }
  let(:telemetry_factory) { AwsAdvancedRubyDriverWrapper::Utils::Telemetry::TelemetryFactory.new(wrapper_props) }
  let(:plugin_manager) do
    manager = pm_class.allocate
    manager.instance_variable_set(:@plugins, [outer_plugin, inner_plugin, base_plugin])
    manager.instance_variable_set(:@pipeline_cache, {})
    manager.instance_variable_set(:@telemetry_factory, telemetry_factory)
    manager
  end

  before do
    allow(pm_class).to receive(:plugin_classes)
      .and_return('outer' => outer_plugin.class, 'inner' => inner_plugin_class, 'base' => base_plugin.class)
  end

  def execute(method_name = 'connection.query', target = -> { :result })
    plugin_manager.execute(method_name, nil, target)
  end

  describe '#execute' do
    it 'records the call as a top-level span with a child span for every plugin, nested in pipeline order' do
      expect(execute).to eq(:result)

      call = span_named('connection.query')
      outer = span_named('outer')
      inner = span_named('inner')
      base = span_named('base')
      expect(call.parent_span_id).to eq(OpenTelemetry::Trace::INVALID_SPAN_ID)
      expect(call.attributes).to include('ruby_call' => 'connection.query')
      expect(call.status.code).to eq(OpenTelemetry::Trace::Status::OK)
      expect(outer.parent_span_id).to eq(call.span_id)
      expect(inner.parent_span_id).to eq(outer.span_id)
      expect(base.parent_span_id).to eq(inner.span_id)
    end

    it 'runs each plugin inside its own span' do
      execute

      expect(outer_plugin.current_spans.map { |span| span.context.span_id }).to eq([span_named('outer').span_id])
    end

    it 'names the span of a plugin that has no plugin code after its class' do
      stub_const('UnregisteredTelemetryPlugin', Class.new(telemetry_test_plugin))
      plugin_manager.instance_variable_get(:@plugins)[1] = UnregisteredTelemetryPlugin.new

      execute

      expect(span_named('UnregisteredTelemetryPlugin').parent_span_id).to eq(span_named('outer').span_id)
    end

    it 'records the error the call failed with on the top-level span' do
      expect { execute('connection.query', -> { raise IOError, 'connection lost' }) }.to raise_error(IOError)

      call = span_named('connection.query')
      expect(call.status.code).to eq(OpenTelemetry::Trace::Status::ERROR)
      expect(call.attributes).to include('exception_type' => 'IOError', 'exception_message' => 'connection lost')
      expect(finished_spans.size).to eq(4)
    end

    it 'records only the plugins subscribed to the method' do
      plugin_manager.instance_variable_get(:@plugins)[1] = inner_plugin_class.new(Set['connection.close'])

      execute

      expect(finished_spans.map(&:name)).to eq(%w[base outer connection.query])
    end

    it 'records no span for the plugin the call skips' do
      in_application_span { plugin_manager.connect(nil, {}, false, plugin_to_skip: outer_plugin) }

      expect(finished_spans.map(&:name)).to eq(%w[base inner connect application])
    end

    it 'records nothing when telemetry is disabled' do
      plugin_manager.instance_variable_set(:@telemetry_factory, AwsAdvancedRubyDriverWrapper::Utils::Telemetry::TelemetryFactory.new({}))

      expect(execute).to eq(:result)
      expect(finished_spans).to be_empty
    end

    it 'records no spans when only metrics are recorded' do
      plugin_manager.instance_variable_set(:@telemetry_factory,
                                           AwsAdvancedRubyDriverWrapper::Utils::Telemetry::TelemetryFactory.new(
                                             telemetry_props(telemetry_traces_backend: 'none')
                                           ))

      expect(in_application_span { execute }).to eq(:result)
      expect(finished_spans.map(&:name)).to eq(['application'])
    end

    it 'records the call as succeeded and restores the current span when a block passed through it is left early' do
      target = ->(&block) { [1, 2, 3].each(&block) }

      in_application_span do |application_span|
        plugin_manager.execute('result.each', nil, target) { |row| break row }

        expect(OpenTelemetry::Trace.current_span).to eq(application_span)
      end
      expect(span_named('result.each').status.code).to eq(OpenTelemetry::Trace::Status::OK)
    end

    it 'adds no telemetry work to a pipeline built while telemetry is not in use' do
      factory = AwsAdvancedRubyDriverWrapper::Utils::Telemetry::NullTelemetryFactory.new
      plugin_manager.instance_variable_set(:@telemetry_factory, factory)
      allow(factory).to receive(:in_context).and_call_original

      execute

      expect(factory).to have_received(:in_context).once
    end
  end

  describe '#connect' do
    it 'records nothing outside of a trace' do
      plugin_manager.connect(nil, {}, true)

      expect(finished_spans).to be_empty
    end

    it 'records the connection as a span with the plugins inside it' do
      expect(in_application_span { plugin_manager.connect(nil, {}, true) }).to eq(:connection)

      connect = span_named('connect')
      expect(span_named('outer').parent_span_id).to eq(connect.span_id)
    end
  end

  describe '#internal_connect' do
    it 'records the connection as a span with the plugins inside it' do
      expect(in_application_span { plugin_manager.internal_connect(nil, {}, {}, false) }).to eq(:connection)

      internal_connect = span_named('internal_connect')
      expect(span_named('outer').parent_span_id).to eq(internal_connect.span_id)
    end
  end

  describe AwsAdvancedRubyDriverWrapper::Plugins::DefaultPlugin do
    let(:driver_dialect) { double('DriverDialect', name: 'pg', connect: :connection) }
    let(:dialect_service) { double('DialectService', driver_dialect: driver_dialect) }
    let(:container) do
      AwsAdvancedRubyDriverWrapper::Services::ServiceContainer.new(dialect_service:, telemetry_factory:)
    end
    let(:plugin) { described_class.new(container, {}) }

    it 'records the time spent in the driver as a span named after the driver' do
      result = in_application_span { plugin.execute('connection.exec', -> { :rows }) }

      expect(result).to eq(:rows)
      expect(span_named('pg').parent_span_id).to eq(span_named('application').span_id)
    end

    it 'records the driver connecting for an internal connection' do
      in_application_span { plugin.internal_connect(nil, {}, {}, false, nil) }

      expect(span_named('pg')).not_to be_nil
    end

    it 'does not look up the driver when only metrics are recorded' do
      container.telemetry_factory = AwsAdvancedRubyDriverWrapper::Utils::Telemetry::TelemetryFactory.new(
        telemetry_props(telemetry_traces_backend: 'none')
      )

      expect(plugin.execute('connection.exec', -> { :rows })).to eq(:rows)
      expect(dialect_service).not_to have_received(:driver_dialect)
    end

    it 'does not look up the driver when telemetry is not in use' do
      container.telemetry_factory = nil

      plugin.execute('connection.exec', -> { :rows })

      expect(dialect_service).not_to have_received(:driver_dialect)
    end
  end
end
