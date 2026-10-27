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
      # The levels a telemetry context can be opened at. Callers name a level with one of these
      # constants, so that a mistyped level raises NameError where it is written.
      module TraceLevel
        # Always starts a new trace, whatever the settings say.
        FORCE_TOP_LEVEL = :force_top_level
        # Starts a new trace when +telemetry_submit_top_level+ is enabled, and is otherwise treated
        # as {NESTED}.
        TOP_LEVEL = :top_level
        # Becomes a child of the current span. Outside of any trace nothing is recorded, so the
        # wrapper does not start traces of its own unless asked to.
        NESTED = :nested
        # Records nothing.
        NO_TRACE = :no_trace
      end

      # Instrumentation scope name the wrapper's tracer and meter are registered under.
      INSTRUMENTATION_NAME = 'aws-advanced-ruby-driver-wrapper'

      # Span attribute names.
      module TelemetryConst
        TRACE_NAME_ANNOTATION = 'trace_name'
        RUBY_CALL_ANNOTATION = 'ruby_call'
        PARENT_TRACE_ANNOTATION = 'parent_trace_id'
        EXCEPTION_TYPE_ANNOTATION = 'exception_type'
        EXCEPTION_MESSAGE_ANNOTATION = 'exception_message'
      end
    end
  end
end
