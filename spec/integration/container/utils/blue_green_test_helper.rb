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

require 'concurrent'

module Integration
  # Immutable struct for recording a timed operation (connection attempt, query execution, etc.)
  TimeHolder = Struct.new(:start_time, :end_time, :error)

  # Immutable struct for recording a host verification result (connecting and checking server IP).
  HostVerificationResult = Struct.new(:timestamp, :connected_host, :original_blue_ip, :connected_to_blue, :error) do
    def success?
      error.nil?
    end
  end

  # Thread-safe results container for a single blue/green instance.
  # Each blue or green instance has its own instance of this class.
  class BlueGreenInstanceResults
    attr_reader :host_id, :host

    def initialize(host_id:, host:)
      @host_id = host_id
      @host = host

      # Atomic timestamps (nanoseconds from Process::CLOCK_MONOTONIC)
      @dns_blue_changed_time = Concurrent::AtomicReference.new(0)
      @dns_green_removed_time = Concurrent::AtomicReference.new(0)
      @direct_blue_lost_connection_time = Concurrent::AtomicReference.new(0)

      @wrapper_green_lost_connection_time = Concurrent::AtomicReference.new(0)
      @green_host_change_name_time = Concurrent::AtomicReference.new(0)

      # Thread-safe arrays for green connectivity monitoring
      @green_wrapper_execute_times = Concurrent::Array.new

      # Status tracking (phase → timestamp)
      @blue_status_times = Concurrent::Map.new
      @green_status_times = Concurrent::Map.new
    end

    # Atomic timestamp accessors — use compare_and_set for first-write-wins semantics
    attr_reader :dns_blue_changed_time, :dns_green_removed_time,
                :direct_blue_lost_connection_time, :wrapper_green_lost_connection_time,
                :green_host_change_name_time

    # Thread-safe collection accessors
    attr_reader :green_wrapper_execute_times,
                :blue_status_times, :green_status_times

    # Records a timestamp atomically (first-write-wins).
    # Returns true if the value was set (first writer), false if already set.
    def record_timestamp(atomic_ref, value = nil)
      value ||= nano_time
      atomic_ref.compare_and_set(0, value)
    end

    private

    def nano_time
      Process.clock_gettime(Process::CLOCK_MONOTONIC, :nanosecond)
    end
  end

  # Thread-safe results container for a single plugin combo on a single host.
  # Used by @combo_results in the orchestrator to track per-combo behavior
  # independently from the existing @instance_results (Option A coexistence).
  class PluginComboResults
    attr_reader :combo, :host_id, :wrapper_pre_switchover_execute_times, :wrapper_post_switchover_execute_times,
                :wrapper_connect_times, :host_verification_results, :failover_success_errors, :failover_failed_errors,
                :bg_timeout_errors, :failover_post_reconnect_successes

    def initialize(combo:, host_id:)
      @combo = combo
      @host_id = host_id

      # Thread-safe arrays for timed operations (non-failover combos)
      @wrapper_pre_switchover_execute_times = Concurrent::Array.new
      @wrapper_post_switchover_execute_times = Concurrent::Array.new
      @wrapper_connect_times = Concurrent::Array.new
      @host_verification_results = Concurrent::Array.new

      # Failover-specific arrays (only populated for combos including 'failover')
      @failover_success_errors = Concurrent::Array.new
      @failover_failed_errors = Concurrent::Array.new
      @bg_timeout_errors = Concurrent::Array.new
      @failover_post_reconnect_successes = Concurrent::Array.new
    end
  end

  # Thread-safe global results not tied to a specific instance.
  class BlueGreenGlobalResults
    def initialize
      # Orchestration timing
      @bg_trigger_time = Concurrent::AtomicReference.new(0)

      # State flags
      @timed_out = Concurrent::AtomicBoolean.new(false)
      @switchover_done = Concurrent::AtomicBoolean.new(false)
      @switchover_post_nano_time = Concurrent::AtomicReference.new(0)
      @rollback = Concurrent::AtomicBoolean.new(false)
      @rollback_final_phase = Concurrent::AtomicReference.new(nil)

      # BG readiness tracking
      @green_topology_recognized_time = Concurrent::AtomicReference.new(0)
      @green_topology_recognized_logged = Concurrent::AtomicBoolean.new(false)

      # Unhandled exceptions from any thread
      @unhandled_exceptions = Concurrent::Array.new
    end

    attr_reader :bg_trigger_time,
                :timed_out, :switchover_done, :switchover_post_nano_time,
                :rollback, :rollback_final_phase,
                :green_topology_recognized_time, :green_topology_recognized_logged,
                :unhandled_exceptions

    # Convenience accessors that match boolean semantics
    def timed_out?
      @timed_out.true?
    end

    def switchover_done?
      @switchover_done.true?
    end

    def rollback?
      @rollback.true?
    end
  end
end
