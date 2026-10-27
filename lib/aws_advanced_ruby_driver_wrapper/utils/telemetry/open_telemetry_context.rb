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

require_relative '../../logging'
require_relative 'telemetry_const'

module AwsAdvancedRubyDriverWrapper
  module Utils
    module Telemetry
      # A span, made the current one for as long as the context is open. Contexts must be closed in
      # the reverse order they were opened, which {TelemetryFactory#in_context} guarantees.
      class OpenTelemetryContext
        include Logging

        attr_reader :name

        def initialize(tracer, name, trace_level)
          @name = name
          parent = OpenTelemetry::Trace.current_span.context
          in_trace = parent.valid?
          trace_level = TraceLevel::NO_TRACE if trace_level == TraceLevel::NESTED && !in_trace

          case trace_level
          when TraceLevel::FORCE_TOP_LEVEL, TraceLevel::TOP_LEVEL
            # A top-level span starts a trace of its own. When there was a trace in progress, the new
            # one is linked to it and records its ID, so the two can still be found together.
            links = in_trace ? [OpenTelemetry::Trace::Link.new(parent)] : nil
            @span = tracer.start_root_span(name, links: links)
            set_attribute(TelemetryConst::PARENT_TRACE_ANNOTATION, parent.hex_trace_id) if in_trace
            set_attribute(TelemetryConst::TRACE_NAME_ANNOTATION, name)
            make_current
            logger.debug { "[OTLP] Telemetry '#{name}' trace ID: #{@span.context.hex_trace_id}" }
          when TraceLevel::NESTED
            @span = tracer.start_span(name)
            set_attribute(TelemetryConst::TRACE_NAME_ANNOTATION, name)
            make_current
          end
        end

        def success=(success)
          return if @span.nil?

          @span.status = success ? OpenTelemetry::Trace::Status.ok : OpenTelemetry::Trace::Status.error
        end

        def set_attribute(key, value)
          @span&.set_attribute(key, value)
        end

        def record_exception(exception)
          return if @span.nil? || exception.nil?

          # The exception event below holds the same details, but span attributes can be filtered and
          # searched on in trace backends, which events often cannot.
          @span.set_attribute(TelemetryConst::EXCEPTION_TYPE_ANNOTATION, exception.class.name)
          @span.set_attribute(TelemetryConst::EXCEPTION_MESSAGE_ANNOTATION, exception.message.to_s)
          @span.record_exception(exception)
        end

        def close
          return if @span.nil?

          @span.finish
          OpenTelemetry::Context.detach(@token)
        end

        private

        def make_current
          @token = OpenTelemetry::Context.attach(OpenTelemetry::Trace.context_with_span(@span))
        end
      end
    end
  end
end
