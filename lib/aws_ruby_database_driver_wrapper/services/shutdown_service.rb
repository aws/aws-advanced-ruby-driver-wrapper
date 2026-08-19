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

require 'singleton'
require_relative '../plugins/blue_green/blue_green_plugin'

module AwsRubyDatabaseDriverWrapper
  module Services
    class ShutdownService
      include Singleton

      def initialize
        @shutdown_targets = []
      end

      def register(shutdown_target)
        @shutdown_targets << shutdown_target
      end

      def shutdown(grace_period_sec = 10)
        Plugins::BlueGreen::BlueGreenPlugin.clean_up_providers

        deadline = Time.now + grace_period_sec

        @shutdown_targets.each do |shutdown_target|
          remaining = remaining_time(deadline)
          break unless remaining.positive?

          shutdown_target.shutdown(grace_period: remaining)
        end
      end

      def shutdown_threads(threads, deadline)
        return if threads.empty?

        threads.each do |thread|
          break if deadline_exceeded?(deadline)

          thread.join(remaining_time(deadline))
          thread.kill if thread.alive?
        end

        threads.clear
      end

      def deadline_exceeded?(deadline)
        Time.now >= deadline
      end

      def remaining_time(deadline)
        [deadline - Time.now, 0].max
      end
    end
  end
end
