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

require_relative '../errors'
require_relative 'host_info'
require_relative 'host_role'

module AwsRubyDatabaseDriverWrapper
  module Host
    # A static host list provider that parses the connection string to determine host information.
    # The host list is determined once during initialization and does not change over time.
    class ConnectionStringHostListProvider
      # @param service_container [Services::ServiceContainer]
      def initialize(service_container:)
        @service_container = service_container
        @hosts = nil
      end

      # Returns the static host list parsed from the connection string.
      # @return [Array<HostInfo>]
      def refresh
        initialize_hosts
        @hosts.dup
      end

      # Same as {#refresh} — the host list is static and never changes.
      # @return [Array<HostInfo>]
      def force_refresh(_verify_writer = false, _timeout_ms = 0)
        initialize_hosts
        @hosts.dup
      end

      # Returns the cluster ID. Since this is a static provider with no cluster awareness,
      # returns a placeholder value.
      # @return [String]
      def cluster_id
        '<none>'
      end

      # No-op — there is no monitor to stop for this host list provider.
      def stop_monitor; end

      private

      def initialize_hosts
        return unless @hosts.nil?

        connection_service = @service_container.connection_service
        config = connection_service.config
        @hosts = if config.multi_host_url?
                   build_multi_host_list(config.original_host, config.original_port)
                 else
                   [connection_service.initial_host_info]
                 end
      end

      def build_multi_host_list(original_host, original_port)
        hosts = original_host.split(',').map(&:strip)
        ports = original_port.split(',', -1)

        # If a single port is specified (no commas), it applies to all hosts.
        # If commas are present, each port maps positionally to each host (empty entries become NO_PORT).
        single_port = !original_port.include?(',')

        hosts.each_with_index.map do |host, i|
          port_value = if single_port
                         original_port.strip.empty? ? HostInfo::NO_PORT : original_host.strip
                       else
                         port = ports[i]&.strip
                         port.nil? || port.empty? ? HostInfo::NO_PORT : port
                       end
          HostInfo.new(host: host, port: port_value, role: HostRole::UNKNOWN)
        end
      end
    end
  end
end
