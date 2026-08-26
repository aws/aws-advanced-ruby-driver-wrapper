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

module AwsRubyDriverWrapper
  module Plugins
    module BlueGreen
      module Routing
        class SuspendConnectRouting
          include BaseRouting

          SLEEP_TIME_SEC = 0.1

          def initialize(host, port, role, bgd_id)
            @host = host
            @port = port
            @role = role
            @bgd_id = bgd_id
          end

          # Blocks until switchover is no longer IN_PROGRESS
          def apply(_host_info, _, wrapper_props, _is_initial_connection, service_container, is_internal: false)
            storage_service = service_container.storage_service
            hold_start_time = Process.clock_gettime(Process::CLOCK_MONOTONIC)

            wait_while_in_progress(wrapper_props, storage_service, @bgd_id, SLEEP_TIME_SEC) do |timeout_ms|
              "Blue/Green Deployment switchover is still in progress after #{timeout_ms} ms. Try to connect again later."
            end

            elapsed_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - hold_start_time) * 1000).round
            logger.debug do
              "Blue/Green Deployment switchover is completed. Continue with connect call. The call was held for #{elapsed_ms} ms."
            end

            nil
          end
        end
      end
    end
  end
end
