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
  module Plugins
    module BlueGreen
      class SwitchoverTimer
        def initialize(timeout_nano)
          @timeout_nano = timeout_nano
          @end_time_nano = 0
        end

        def start
          @end_time_nano = nano_time + @timeout_nano if @end_time_nano.zero?
        end

        def expired?
          @end_time_nano.positive? && @end_time_nano < nano_time
        end

        def reset
          @end_time_nano = 0
        end

        private

        def nano_time
          Process.clock_gettime(Process::CLOCK_MONOTONIC, :nanosecond)
        end
      end
    end
  end
end
