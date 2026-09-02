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
require 'concurrent'

module AwsAdvancedRubyDriverWrapper
  module Monitoring
    # Base class for all monitors. Manages thread lifecycle, state transitions,
    # and activity tracking. Subclasses implement #monitor with their polling logic.
    class Monitor
      include Logging

      attr_reader :last_activity_sec

      def state
        @state.value
      end

      def initialize(termination_timeout_sec: 30.0)
        @termination_timeout_sec = termination_timeout_sec
        @state = Concurrent::AtomicReference.new(nil)
        @stop_flag = Concurrent::AtomicBoolean.new(false)
        update_activity
        @thread = nil
        @lock = Mutex.new
      end

      def start
        @lock.synchronize do
          return if @state.value == MonitorState::RUNNING

          @stop_flag.make_false
          @state.set(MonitorState::RUNNING)
          @thread = Thread.new { run }
          @thread.name = "monitor-#{monitor_thread_suffix}"
          logger.debug("Started monitoring thread: #{@thread.name}")
        end
      end

      def stop
        @stop_flag.make_true

        thread = @thread
        if thread&.alive? && thread != Thread.current
          thread.join(@termination_timeout_sec)
          thread.kill if thread.alive?
        end
        @thread = nil

        @state.set(MonitorState::STOPPED)
        close
        logger.debug("Stopped monitoring thread: monitor-#{monitor_thread_suffix}")
      end

      def stopped?
        @stop_flag.true?
      end

      def close; end

      private

      def run
        monitor
      rescue StandardError => e
        logger.error("Exception in monitoring thread monitor-#{monitor_thread_suffix}: #{e.message}")
        @state.set(MonitorState::ERROR)
      ensure
        @state.compare_and_set(MonitorState::RUNNING, MonitorState::STOPPED)
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
