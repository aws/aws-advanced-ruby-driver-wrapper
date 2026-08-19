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
require_relative 'phase'
require_relative 'phase_time_info'

module AwsRubyDatabaseDriverWrapper
  module Plugins
    module BlueGreen
      # Ordered log of timestamped events during a switchover (phase transitions, DNS changes,
      # monitor resets). Used to produce the final switchover summary printed at completion.
      class PhaseEventLog
        def initialize
          @entries = Concurrent::Hash.new
        end

        # Records an event with the current wall-clock and monotonic timestamps.
        # Only the first occurrence of each label is kept (idempotent).
        def record(label, rollback_suffix, phase: nil)
          @entries["#{label}#{rollback_suffix}"] ||= PhaseTimeInfo.new(Time.now, nano_time, phase)
        end

        def clear
          @entries.clear
        end

        def any?(&)
          @entries.any?(&)
        end

        # Formats a human-readable switchover summary table with timestamps and ms offsets
        # relative to the IN_PROGRESS (or PREPARATION for rollback) phase start time.
        def summary(bgd_id, rollback)
          left_pad = 5
          default_field = 31
          max_name_len = @entries.keys.map { |k| k.length + left_pad }.max || default_field

          time_zero_phase = rollback ? Phase::PREPARATION : Phase::IN_PROGRESS
          suffix = rollback ? ' (rollback)' : ''
          time_zero = @entries["#{time_zero_phase}#{suffix}"] || (rollback && @entries[time_zero_phase.to_s])

          divider = "---------------------------------------------------#{'-' * max_name_len}\n"
          status_label = rollback ? 'ROLLED BACK' : 'COMPLETED'

          header = "#{'timestamp'.ljust(28)} #{'time offset (ms)'.rjust(21)} #{'event'.rjust(max_name_len)}"

          rows = @entries
                 .sort_by { |_, v| v.timestamp_nano }
                 .map do |k, v|
                   offset = time_zero ? ((v.timestamp_nano - time_zero.timestamp_nano) / 1_000_000) : ''
                   "#{v.timestamp.to_s.rjust(28)} #{offset.to_s.rjust(18)} ms #{k.rjust(max_name_len)}"
                 end
            .join("\n")

          "[bgd_id: '#{bgd_id}'] Blue/Green Deployment Switchover #{status_label}\n" \
            "#{divider}#{header}\n#{divider}#{rows}\n#{divider}"
        end

        def to_debug_s
          @entries.map { |k, v| "   #{k} -> #{v.timestamp}" }.join("\n")
        end

        private

        def nano_time
          Process.clock_gettime(Process::CLOCK_MONOTONIC, :nanosecond)
        end
      end
    end
  end
end
