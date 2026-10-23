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

module AwsAdvancedRubyDriverWrapper
  module Utils
    module Telemetry
      # The levels a telemetry context can be opened at:
      #
      # - +:force_top_level+ - always starts a new trace, whatever the settings say.
      # - +:top_level+ - starts a new trace when +telemetry_submit_top_level+ is enabled, and is
      #   otherwise treated as +:nested+.
      # - +:nested+ - becomes a child of the current span. Outside of any trace nothing is recorded,
      #   so the wrapper does not start traces of its own unless asked to.
      # - +:no_trace+ - records nothing.
      TRACE_LEVELS = %i[force_top_level top_level nested no_trace].freeze

      # Checked whether or not traces are recorded, so that a mistyped level fails wherever it is
      # used rather than only once tracing is turned on.
      #
      # @raise [ArgumentError] unless the level is one of {TRACE_LEVELS}
      def self.validate_trace_level!(trace_level)
        raise ArgumentError, "Unknown trace level: #{trace_level.inspect}" unless TRACE_LEVELS.include?(trace_level)
      end

      # Instrumentation scope name the wrapper's tracer and meter are registered under.
      INSTRUMENTATION_NAME = 'aws-advanced-ruby-driver-wrapper'

      # Span attribute names, and the prefix of the name of a copied span.
      module TelemetryConst
        TRACE_NAME_ANNOTATION = 'trace_name'
        RUBY_CALL_ANNOTATION = 'ruby_call'
        PARENT_TRACE_ANNOTATION = 'parent_trace_id'
        EXCEPTION_TYPE_ANNOTATION = 'exception_type'
        EXCEPTION_MESSAGE_ANNOTATION = 'exception_message'
        SOURCE_TRACE_ANNOTATION = 'source_trace_id'
        COPY_TRACE_NAME_PREFIX = 'copy: '
      end
    end
  end
end
