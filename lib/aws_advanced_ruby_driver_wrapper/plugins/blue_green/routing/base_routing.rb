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

require_relative '../../../logging'

module AwsAdvancedRubyDriverWrapper
  module Plugins
    module BlueGreen
      module Routing
        module BaseRouting
          include Logging

          MINIMUM_SLEEP_CHUNK_SEC = 0.05

          def match?(host_info, role)
            (@host.nil? || @host.downcase == host_info&.host&.downcase) &&
              (@port.nil? || @port == host_info&.port) &&
              (@role.nil? || @role == role)
          end

          def to_s
            "#{self.class.name.split('::').last}@#{object_id.to_s(16)} [" \
              "host: #{@host || '<null>'}, " \
              "port: #{@port || '<null>'}, " \
              "role: #{@role || '<null>'}, " \
              "bgd_id: #{defined?(@bgd_id) ? (@bgd_id || '<null>') : '<n/a>'}]"
          end

          # Blocks until the Blue/Green switchover phase is no longer IN_PROGRESS, or until the
          # configured timeout elapses.
          def wait_while_in_progress(wrapper_props, storage_service, bgd_id, sleep_time_sec = MINIMUM_SLEEP_CHUNK_SEC)
            bg_status = storage_service.get(BlueGreenPlugin::BLUE_GREEN_NAME, bgd_id)
            remaining_sec = PropertyDefinition::BG_CONNECT_TIMEOUT_SEC.get_float(wrapper_props)

            while remaining_sec.positive? && bg_status&.current_phase == Phase::IN_PROGRESS
              sleep_sec = [sleep_time_sec, remaining_sec].min
              delay(sleep_sec, bg_status, storage_service, bgd_id)
              remaining_sec -= sleep_sec
              bg_status = storage_service.get(BlueGreenPlugin::BLUE_GREEN_NAME, bgd_id)
            end

            if bg_status&.current_phase == Phase::IN_PROGRESS
              raise Errors::BlueGreenTimeoutError, yield(PropertyDefinition::BG_CONNECT_TIMEOUT_SEC.get_float(wrapper_props))
            end

            bg_status
          end

          protected

          def delay(delay_sec, bg_status, storage_service, bgd_id)
            if bg_status.nil?
              sleep(delay_sec)
            else
              deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + delay_sec
              min_delay = [delay_sec, MINIMUM_SLEEP_CHUNK_SEC].min

              # Wake early if the status reference changes or the deadline passes.
              # Thread interruption surfaces as Interrupt raised into bg_status.wait, unwinding the caller.
              until Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline ||
                    bg_status != storage_service.get(BlueGreenPlugin::BLUE_GREEN_NAME, bgd_id)
                bg_status.wait(min_delay * 1000)
              end
            end
          end
        end
      end
    end
  end
end
