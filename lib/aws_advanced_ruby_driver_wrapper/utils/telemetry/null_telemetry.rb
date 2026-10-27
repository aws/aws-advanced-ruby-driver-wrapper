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
      # Stands in for a context when no span is recorded, so callers never have to check for nil.
      class NullTelemetryContext
        INSTANCE = new.freeze

        def name
          'null'
        end

        def success=(_success); end

        def set_attribute(_key, _value); end

        def record_exception(_exception); end

        def close; end
      end

      class NullTelemetryCounter
        INSTANCE = new.freeze

        def name
          'null'
        end

        def add(_value); end

        def inc; end
      end

      class NullTelemetryGauge
        INSTANCE = new.freeze

        def name
          'null'
        end
      end

      # The factory used when telemetry is disabled.
      class NullTelemetryFactory
        def open_telemetry_context(_name, _trace_level)
          NullTelemetryContext::INSTANCE
        end

        def in_context(_name, _trace_level, record_result: false, record_failure: false)
          yield NullTelemetryContext::INSTANCE
        end

        def post_copy(_context, _trace_level); end

        def create_counter(_name)
          NullTelemetryCounter::INSTANCE
        end

        def create_gauge(_name, &)
          NullTelemetryGauge::INSTANCE
        end

        def in_use?
          false
        end

        def traces_in_use?
          false
        end

        INSTANCE = new.freeze
      end
    end
  end
end
