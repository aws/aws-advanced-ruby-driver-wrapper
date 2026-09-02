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
      module Routing
        # Suspends a new connection attempt until a corresponding green host is found for the
        # requested host, or until the switchover completes.
        class SuspendUntilCorrespondingHostFoundConnectRouting
          include BaseRouting

          SLEEP_TIME_SEC = 0.1

          def initialize(host, port, role, bgd_id)
            @host = host
            @port = port
            @role = role
            @bgd_id = bgd_id
          end

          # Blocks until a corresponding green host is found for host_info.host, the switchover
          # completes, or the timeout elapses.
          def apply(host_info, _, wrapper_props, _is_initial_connection, service_container, is_internal: false)
            storage_service = service_container.storage_service

            bg_status = storage_service.get(BlueGreenPlugin::BLUE_GREEN_NAME, @bgd_id)
            corresponding_pair = bg_status&.corresponding_hosts&.[](host_info.host)

            timeout_sec = PropertyDefinition::BG_CONNECT_TIMEOUT_MS.get_int(wrapper_props) / 1000.0
            hold_start_time = Process.clock_gettime(Process::CLOCK_MONOTONIC)
            end_time = hold_start_time + timeout_sec

            # Wait until a corresponding host is found, or until switchover is completed.
            while Process.clock_gettime(Process::CLOCK_MONOTONIC) <= end_time &&
                  !bg_status.nil? &&
                  bg_status.current_phase != Phase::COMPLETED &&
                  (corresponding_pair.nil? || corresponding_pair[1].nil?)
              delay(SLEEP_TIME_SEC, bg_status, storage_service, @bgd_id)
              bg_status = storage_service.get(BlueGreenPlugin::BLUE_GREEN_NAME, @bgd_id)
              corresponding_pair = bg_status&.corresponding_hosts&.[](host_info.host)
            end

            elapsed_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - hold_start_time) * 1000).round

            if bg_status.nil? || bg_status.current_phase == Phase::COMPLETED
              logger.debug do
                "Blue/Green Deployment status is completed. Continue with 'connect' call. The call was held for #{elapsed_ms} ms."
              end
              return nil
            end

            if Process.clock_gettime(Process::CLOCK_MONOTONIC) > end_time
              raise Errors::BlueGreenTimeoutError,
                    'Blue/Green Deployment switchover is still in progress and a corresponding ' \
                    "host for '#{host_info.host}' is not found after " \
                    "#{PropertyDefinition::BG_CONNECT_TIMEOUT_MS.get_int(wrapper_props)} ms. Try to connect again later."
            end

            logger.debug do
              "A corresponding host for '#{host_info.host}' is found. Continue with connect call. The call was held for #{elapsed_ms} ms."
            end

            nil
          end
        end
      end
    end
  end
end
