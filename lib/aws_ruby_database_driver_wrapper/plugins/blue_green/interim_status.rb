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

module AwsRubyDatabaseDriverWrapper
  module Plugins
    module BlueGreen
      InterimStatus = Struct.new(
        :blue_green_phase,
        :version,
        :port,
        :start_topology,
        :current_topology,
        :start_ip_addresses_by_host,
        :current_ip_addresses_by_host,
        :host_names,
        :all_start_topology_ip_changed,
        :all_start_topology_endpoints_removed,
        :all_topology_changed
      ) do
        def to_s
          start_ip_map     = format_map(start_ip_addresses_by_host)
          current_ip_map   = format_map(current_ip_addresses_by_host)
          host_names_str   = host_names&.join("\n   ")
          start_topo_str   = log_topology(start_topology)
          current_topo_str = log_topology(current_topology)

          <<~STATUS
            #{super} [
             phase #{blue_green_phase || '<null>'},
             version '#{version}',
             port #{port},
             hostNames:
               #{blank?(host_names_str) ? '-' : host_names_str}
             Start #{blank?(start_topo_str) ? '-' : start_topo_str}
             start IP map:
               #{blank?(start_ip_map) ? '-' : start_ip_map}
             Current #{blank?(current_topo_str) ? '-' : current_topo_str}
             current IP map:
               #{blank?(current_ip_map) ? '-' : current_ip_map}
             allStartTopologyIpChanged: #{all_start_topology_ip_changed}
             allStartTopologyEndpointsRemoved: #{all_start_topology_endpoints_removed}
             allTopologyChanged: #{all_topology_changed}
            ]
          STATUS
        end

        def hash
          [blue_green_phase, version, port, all_start_topology_ip_changed,
           all_start_topology_endpoints_removed, all_topology_changed,
           host_names&.sort, topology_hash_str(start_topology),
           topology_hash_str(current_topology), ip_map_hash_str(start_ip_addresses_by_host),
           ip_map_hash_str(current_ip_addresses_by_host)].hash
        end

        private

        def format_map(map)
          map&.map { |k, v| "#{k} -> #{v}" }&.join("\n   ").to_s
        end

        def log_topology(topology)
          topology&.map { |h| "#{h.host_and_port} #{h.role}" }&.join(', ').to_s
        end

        def topology_hash_str(topology)
          topology&.map { |h| "#{h.host_and_port}#{h.role}" }&.sort&.join(',').to_s
        end

        def ip_map_hash_str(map)
          map&.map { |k, v| "#{k}#{v}" }&.sort&.join(',').to_s
        end

        def blank?(str)
          str.nil? || str.empty?
        end
      end
    end
  end
end
