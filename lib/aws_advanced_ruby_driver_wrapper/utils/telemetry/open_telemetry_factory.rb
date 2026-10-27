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

require_relative '../../version'
require_relative 'telemetry_const'
require_relative 'open_telemetry_context'
require_relative 'open_telemetry_counter'
require_relative 'open_telemetry_gauge'

module AwsAdvancedRubyDriverWrapper
  module Utils
    module Telemetry
      # Records telemetry through the OpenTelemetry API. The application owns the SDK: it installs
      # the tracer and meter providers and the exporters, and until it does, the API discards what is
      # recorded here.
      #
      # The OpenTelemetry gems are optional dependencies of the wrapper, so they are only loaded
      # when a backend that needs them is selected.
      module OpenTelemetryFactory
        NAME_MAX_LENGTH = 255

        @gauges = {}
        @gauges_lock = Mutex.new

        class << self
          def require_traces_api!
            require 'opentelemetry-api'
          rescue LoadError
            raise LoadError,
                  "telemetry_traces_backend 'otlp' requires 'opentelemetry-api'. " \
                  "Add it to your Gemfile: gem 'opentelemetry-api' (or gem 'opentelemetry-sdk')"
          end

          def require_metrics_api!
            require 'opentelemetry-metrics-api'
            begin
              # Since opentelemetry-metrics-api 0.9.0, OpenTelemetry.meter_provider is only defined
              # once this is required. Earlier versions define it as soon as the API is loaded.
              require 'opentelemetry/metrics/global'
            rescue LoadError
              nil
            end
          rescue LoadError
            raise LoadError,
                  "telemetry_metrics_backend 'otlp' requires 'opentelemetry-metrics-api'. " \
                  "Add it to your Gemfile: gem 'opentelemetry-metrics-api' (or gem 'opentelemetry-metrics-sdk')"
          end

          def open_telemetry_context(name, trace_level)
            OpenTelemetryContext.new(tracer, name, trace_level)
          end

          def post_copy(context, trace_level)
            return if trace_level == TraceLevel::NO_TRACE || !context.is_a?(OpenTelemetryContext)
            # A top-level copy must not find the trace in progress, or it would be linked to that trace
            # as well as to the span it copies.
            return context.record_copy(trace_level) if trace_level == TraceLevel::NESTED

            OpenTelemetry::Context.with_current(OpenTelemetry::Context.empty) { context.record_copy(trace_level) }
          end

          # Unlike gauges, counters need no registry: creating one again under the same name returns the
          # instrument the meter already has, so every counter object adds to the same total.
          def create_counter(name)
            OpenTelemetryCounter.new(meter, trim(name))
          end

          # There is one gauge per name for the whole process, since every connection records through
          # the same meter. Creating a gauge that already exists replaces its callback, so the gauge
          # reports the value of the callback set last.
          def create_gauge(name, callback)
            name = trim(name)
            @gauges_lock.synchronize do
              gauge = (@gauges[name] ||= OpenTelemetryGauge.new(meter, name))
              gauge.callback = callback
              gauge
            end
          end

          # Stops every gauge from reporting until it is created again: a gauge without a callback is
          # skipped when metrics are collected. The gauges themselves stay registered, since
          # registering one again under the same name would not take a new callback. For testing only.
          #
          # @api private
          def clear_gauge_callbacks!
            @gauges_lock.synchronize { @gauges.each_value { |gauge| gauge.callback = nil } }
          end

          private

          # Both are safe to keep: until the application installs its SDK, the API hands out proxies
          # that start delegating to the SDK once it is installed.
          def tracer
            @tracer ||= OpenTelemetry.tracer_provider.tracer(INSTRUMENTATION_NAME, VERSION)
          end

          def meter
            @meter ||= OpenTelemetry.meter_provider.meter(INSTRUMENTATION_NAME, version: VERSION)
          end

          def trim(name)
            name.length > NAME_MAX_LENGTH ? name[0, NAME_MAX_LENGTH] : name
          end
        end
      end
    end
  end
end
