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

module AwsRubyDatabaseDriverWrapper
  module Plugins
    module BlueGreen
      class Status
        attr_reader :bgd_id, :current_phase, :connect_routing, :execute_routing, :role_by_host, :corresponding_hosts

        def initialize(bgd_id, phase, connect_routing: [], execute_routing: [], role_by_host: {}, corresponding_hosts: {})
          @bgd_id = bgd_id
          @current_phase = phase
          @connect_routing = connect_routing.freeze
          @execute_routing = execute_routing.freeze
          @role_by_host = role_by_host.dup.freeze
          @corresponding_hosts = corresponding_hosts.dup.freeze
          @event = Concurrent::Event.new
        end

        def wait(timeout_ms)
          @event.wait(timeout_ms / 1000.0)
        end

        def notify
          @event.set
        end

        def role(host_spec)
          @role_by_host[host_spec.host.downcase]
        end

        def to_s
          role_map = @role_by_host.map { |k, v| "#{k} -> #{v}" }.join("\n")
          connect_str = @connect_routing.join("\n")
          execute_str = @execute_routing.join("\n")

          <<~STATUS
            #{super} [
             bgdId: '#{@bgd_id}',
             phase: #{@current_phase},
             Connect routing:
               #{connect_str.empty? ? '-' : connect_str}
             Execute routing:
               #{execute_str.empty? ? '-' : execute_str}
             roleByHost:
               #{role_map.empty? ? '-' : role_map}
            ]
          STATUS
        end
      end
    end
  end
end
