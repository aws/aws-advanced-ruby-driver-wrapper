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

require_relative 'monitor_state'
require_relative '../logging'
require_relative '../log_messages'

module AwsRubyDatabaseDriverWrapper
  module Monitoring
    # Base class for all monitors. Manages thread lifecycle, state transitions,
    # and activity tracking. Subclasses implement #monitor with their polling logic.
    class Monitor
      include Logging

      attr_reader :state, :last_activity_sec

      def initialize(termination_timeout_sec: 30)
        @termination_timeout_sec = termination_timeout_sec
        @state = nil
        @stop_flag = false
        update_activity
        @thread = nil
        @lock = Mutex.new
      end

      def start
        @lock.synchronize do
          return if @state == MonitorState::RUNNING

          @stop_flag = false
          @state = MonitorState::RUNNING
          @thread = Thread.new { run }
          @thread.name = "monitor-#{monitor_thread_suffix}"
          LOGGER.debug(format(LogMessages::MONITOR_STARTED, @thread.name))
        end
      end

      def stop
        @stop_flag = true

        thread = @thread
        if thread&.alive?
          thread.join(@termination_timeout_sec)
          thread.kill if thread.alive?
        end

        @state = MonitorState::STOPPED
        close
        LOGGER.debug(format(LogMessages::MONITOR_STOPPED, "monitor-#{monitor_thread_suffix}"))
      end

      def stopped?
        @stop_flag
      end

      def close; end

      private

      def run
        monitor
      rescue StandardError => e
        LOGGER.error(format(LogMessages::MONITOR_EXCEPTION, "monitor-#{monitor_thread_suffix}", e.message))
        @state = MonitorState::ERROR
      ensure
        @lock.synchronize { @state = MonitorState::STOPPED if @state == MonitorState::RUNNING }
      end

      def monitor_thread_suffix
        class_name = self.class.name
        return 'unknown' unless class_name

        class_name.split('::').last.downcase
      end

      def update_activity
        @last_activity_sec = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end
    end
  end
end
