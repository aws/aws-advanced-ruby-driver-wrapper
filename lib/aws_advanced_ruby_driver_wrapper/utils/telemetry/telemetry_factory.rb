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

require_relative '../../errors'
require_relative '../../property_definition'
require_relative 'telemetry_const'
require_relative 'null_telemetry'
require_relative 'open_telemetry_factory'

module AwsAdvancedRubyDriverWrapper
  module Utils
    module Telemetry
      # Records the wrapper's traces and metrics through the backends selected by the connection
      # properties. Traces and metrics are configured separately; whichever is disabled is not recorded.
      class TelemetryFactory
        TRACES_BACKENDS = { 'otlp' => OpenTelemetryFactory, 'none' => nil }.freeze
        METRICS_BACKENDS = { 'otlp' => OpenTelemetryFactory, 'none' => nil }.freeze

        # @param wrapper_props [Hash, Concurrent::Map] the wrapper properties of the connection
        # @raise [Errors::AwsError] if telemetry is enabled and a backend is missing or not recognized
        # @raise [LoadError] if a selected backend's gem is not installed
        def initialize(wrapper_props)
          @submit_top_level = PropertyDefinition::TELEMETRY_SUBMIT_TOP_LEVEL.get_bool(wrapper_props)

          if PropertyDefinition::ENABLE_TELEMETRY.get_bool(wrapper_props)
            @traces_factory = backend(PropertyDefinition::TELEMETRY_TRACES_BACKEND, TRACES_BACKENDS, wrapper_props)
            @metrics_factory = backend(PropertyDefinition::TELEMETRY_METRICS_BACKEND, METRICS_BACKENDS, wrapper_props)
          end

          @traces_factory&.require_traces_api!
          @metrics_factory&.require_metrics_api!
        end

        # Opens a context that the caller must close. Prefer {#in_context}, which closes it.
        #
        # @param name [String] the span name
        # @param trace_level [Symbol] one of {TRACE_LEVELS}
        # @return [OpenTelemetryContext, NullTelemetryContext]
        def open_telemetry_context(name, trace_level)
          Telemetry.validate_trace_level!(trace_level)
          return NullTelemetryContext::INSTANCE if @traces_factory.nil?

          trace_level = :nested if trace_level == :top_level && !@submit_top_level
          @traces_factory.open_telemetry_context(name, trace_level)
        end

        # Runs the block inside a new context and closes the context when the block finishes.
        #
        # @param record_result [Boolean] whether to mark the span as succeeded or failed according to
        #   how the block finishes. An error raised by the block marks it failed and is recorded on the
        #   span. Leaving the block early with +break+, +next+, +return+ or +throw+ is not an error, so
        #   it marks the span as succeeded.
        # @yieldparam context [OpenTelemetryContext, NullTelemetryContext]
        # @return the block's result
        def in_context(name, trace_level, record_result: false)
          if @traces_factory.nil?
            Telemetry.validate_trace_level!(trace_level)
            return yield NullTelemetryContext::INSTANCE
          end

          context = open_telemetry_context(name, trace_level)
          failed = false
          begin
            yield context
          rescue Exception => e # rubocop:disable Lint/RescueException -- recorded, then re-raised
            failed = true
            context.record_exception(e) if record_result
            raise
          ensure
            context.success = !failed if record_result
            context.close
          end
        end

        # @return [OpenTelemetryCounter, NullTelemetryCounter]
        def create_counter(name)
          return NullTelemetryCounter::INSTANCE if @metrics_factory.nil?

          @metrics_factory.create_counter(name)
        end

        # A gauge reports one value for the whole process: creating a gauge with a name that already
        # exists, from this connection or any other, replaces the callback it is read from. So the
        # callback should report state shared by all connections (such as the size of a shared
        # cache) rather than state of its own connection.
        #
        # @yieldreturn [Numeric] the gauge's current value, read each time metrics are collected
        # @return [OpenTelemetryGauge, NullTelemetryGauge]
        def create_gauge(name, &callback)
          return NullTelemetryGauge::INSTANCE if @metrics_factory.nil?

          @metrics_factory.create_gauge(name, callback)
        end

        # @return [Boolean] whether traces or metrics are being recorded
        def in_use?
          traces_in_use? || !@metrics_factory.nil?
        end

        # @return [Boolean] whether traces are being recorded
        def traces_in_use?
          !@traces_factory.nil?
        end

        private

        def backend(property, backends, wrapper_props)
          value = property.get_string(wrapper_props)
          key = value&.downcase
          return backends[key] if backends.key?(key)

          raise Errors::AwsError,
                "#{value.inspect} is not a valid #{property.name}. " \
                "When enable_telemetry is true, #{property.name} must be one of: #{backends.keys.join(', ')}"
        end
      end
    end
  end
end
