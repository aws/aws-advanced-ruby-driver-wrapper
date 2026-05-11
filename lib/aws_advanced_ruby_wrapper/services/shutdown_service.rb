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

module AwsAdvancedRubyWrapper
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
        deadline = Time.now + grace_period_sec

        @shutdown_targets.each do |shutdown_target|
          remaining = remaining_time(deadline)
          if remaining.positive?
            shutdown_target.shutdown(grace_period: remaining)
          else
            break
          end
        end
      end

      def shutdown_threads(threads, deadline)
        return if threads.empty?

        threads.each do |thread|
          break if deadline_exceeded?(deadline)

          thread.join(remaining_time(deadline))
        end

        # Force kill any remaining alive threads
        threads.each { |t| t.kill if t.alive? }
        threads.clear
      end

      def close_connections(connections, deadline)
        return if connections.empty?

        connections.each do |conn|
          conn.close unless conn.closed?
        rescue StandardError => e
          # Suppress errors during shutdown
          warn "Error closing connection: #{e.message}" unless deadline_exceeded?(deadline)
        end

        connections.clear
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
