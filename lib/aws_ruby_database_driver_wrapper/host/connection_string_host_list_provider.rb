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

      # Force monitoring refresh is not supported for static host list providers.
      # @raise [Errors::AwsError]
      def force_monitoring_refresh(_verify_writer, _timeout_ms)
        raise Errors::AwsError, 'force_monitoring_refresh is not supported for ConnectionStringHostListProvider'
      end

      # No-op — there is no monitor to stop for a static provider.
      def stop_monitor; end

      private

      def initialize_hosts
        return unless @hosts.nil?

        initial_host = @service_container.connection_service.initial_host_info
        @hosts = [initial_host]
      end
    end
  end
end
