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
require_relative '../../logging'
require_relative 'role'

module AwsRubyDatabaseDriverWrapper
  module Plugins
    module BlueGreen
      # Tracks DNS and topology change milestones during a switchover.
      # Fires callbacks when each milestone is first reached so StatusProvider can
      # record events and trigger monitor resets at the right moments.
      class SwitchoverState
        include Logging

        attr_reader :blue_dns_update_completed, :green_dns_removed, :green_topology_changed

        def initialize(on_monitor_reset:, on_event:)
          @on_monitor_reset = on_monitor_reset
          @on_event         = on_event

          @blue_dns_update_completed = false
          @green_dns_removed         = false
          @green_topology_changed    = false

          @monitor_reset_on_in_progress_completed = Concurrent::AtomicBoolean.new(false)
          @monitor_reset_on_topology_completed    = Concurrent::AtomicBoolean.new(false)
        end

        def update_dns_flags(bgd_id, role, interim_status)
          if role == Role::SOURCE && !@blue_dns_update_completed && interim_status.all_start_topology_ip_changed
            logger.debug { "[bgdId: '#{bgd_id}'] Blue DNS update completed." }
            @blue_dns_update_completed = true
            @on_event.call('Blue DNS updated')
          end

          return unless role == Role::TARGET

          if !@green_dns_removed && interim_status.all_start_topology_endpoints_removed
            logger.debug { "[bgdId: '#{bgd_id}'] Green DNS removed." }
            @green_dns_removed = true
            @on_event.call('Green DNS removed')
          end

          return unless !@green_topology_changed && interim_status.all_topology_changed

          logger.debug { "[bgdId: '#{bgd_id}'] Green topology changed." }
          @green_topology_changed = true
          @on_event.call('Green topology changed')
          trigger_monitor_reset(@monitor_reset_on_topology_completed, '- green topology')
        end

        def trigger_in_progress_monitor_reset
          trigger_monitor_reset(@monitor_reset_on_in_progress_completed, '- start')
        end

        def reset
          @blue_dns_update_completed = false
          @green_dns_removed         = false
          @green_topology_changed    = false
          @monitor_reset_on_in_progress_completed.make_false
          @monitor_reset_on_topology_completed.make_false
        end

        def to_debug_s(iam_tracker)
          "   blue_dns_update_completed: #{@blue_dns_update_completed}\n   " \
            "green_dns_removed: #{@green_dns_removed}\n   " \
            "green_host_changed_name: #{iam_tracker.all_changed?}\n   " \
            "green_topology_changed: #{@green_topology_changed}"
        end

        private

        def trigger_monitor_reset(flag, event_name)
          return unless flag.false?
          return unless flag.make_true

          @on_monitor_reset.call(event_name)
          @on_event.call("Monitors reset #{event_name}")
        end
      end
    end
  end
end
