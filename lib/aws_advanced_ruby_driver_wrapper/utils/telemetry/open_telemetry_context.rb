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

        # @param start_timestamp [Time, nil] when the span started; now when nil
        # @param links [Array<OpenTelemetry::Trace::Link>] spans the new span is linked to
        def initialize(tracer, name, trace_level, start_timestamp: nil, links: [])
          @name = name
          @tracer = tracer
          parent = OpenTelemetry::Trace.current_span.context
          in_trace = parent.valid?
          trace_level = :no_trace if trace_level == :nested && !in_trace

          case trace_level
          when :force_top_level, :top_level
            # A top-level span starts a trace of its own. When there was a trace in progress, the new
            # one is linked to it and records its ID, so the two can still be found together.
            links += [OpenTelemetry::Trace::Link.new(parent)] if in_trace
            @span = tracer.start_root_span(name, links: links.empty? ? nil : links, start_timestamp: start_timestamp)
            set_attribute(TelemetryConst::PARENT_TRACE_ANNOTATION, parent.hex_trace_id) if in_trace
            set_attribute(TelemetryConst::TRACE_NAME_ANNOTATION, name)
            make_current
            logger.debug { "[OTLP] Telemetry '#{name}' trace ID: #{@span.context.hex_trace_id}" }
          when :nested
            @span = tracer.start_span(name, links: links.empty? ? nil : links, start_timestamp: start_timestamp)
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

        # @param end_timestamp [Time, nil] when the span ended; now when nil
        def close(end_timestamp: nil)
          return if @span.nil?

          @span.finish(end_timestamp: end_timestamp)
          OpenTelemetry::Context.detach(@token)
        end

        # Records a copy of this context's span at the given trace level: same start and end times,
        # attributes and status, linked to the original and carrying its trace ID. Used to submit a
        # span that was recorded inside another trace as a trace of its own as well.
        #
        # Does nothing when the span cannot be read back, as with the no-op spans the OpenTelemetry API
        # hands out before an SDK is installed.
        def record_copy(trace_level)
          return if @span.nil? || !@span.respond_to?(:to_span_data)

          original = @span.to_span_data
          copy = OpenTelemetryContext.new(
            @tracer, "#{TelemetryConst::COPY_TRACE_NAME_PREFIX}#{name}", trace_level,
            start_timestamp: nanoseconds_to_time(original.start_timestamp), links: [OpenTelemetry::Trace::Link.new(@span.context)]
          )
          original.attributes&.each do |key, value|
            copy.set_attribute(key, value) unless key == TelemetryConst::TRACE_NAME_ANNOTATION
          end
          copy.span&.status = original.status
          copy.set_attribute(TelemetryConst::SOURCE_TRACE_ANNOTATION, original.hex_trace_id)
          copy.close(end_timestamp: nanoseconds_to_time(original.end_timestamp))
        end

        protected

        attr_reader :span

        private

        # Recorded spans report their timestamps as nanoseconds since the epoch, but new spans are given
        # theirs as times.
        def nanoseconds_to_time(nanoseconds)
          nanoseconds && Time.at(0, nanoseconds, :nanosecond)
        end

        def make_current
          @token = OpenTelemetry::Context.attach(OpenTelemetry::Trace.context_with_span(@span))
        end
      end
    end
  end
end
