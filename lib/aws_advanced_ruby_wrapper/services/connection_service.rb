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

module AwsAdvancedRubyWrapper
  module Services
    class ConnectionService
      # @param config [Utils::ConnectionConfig] the parsed connection configuration
      def initialize(config)
        @config = config
      end

      # @return [Object, nil] the current active connection
      def current_connection
        raise NotImplementedError
      end

      # @return [Host::HostInfo, nil] host info for the current connection
      def current_host_info
        raise NotImplementedError
      end

      # @param connection [Object] the new connection
      # @param host_info [Host::HostInfo] host info for the new connection
      # @return [Set<Symbol>] set of node change options describing what changed
      def set_current_connection(connection, host_info)
        raise NotImplementedError
      end

      # @return [Host::HostInfo, nil] host info for the initial connection
      def initial_host_info
        @config.initial_host_info
      end

      # @param host_info [Host::HostInfo]
      def initial_host_info=(host_info)
        @config.initial_host_info = host_info
      end

      # @return [Symbol] the driver name (e.g. :postgresql, :mysql2)
      def driver_name
        @config.driver_name
      end

      # @return [Hash] wrapper-specific properties
      def wrapper_props
        @config.wrapper_props
      end

      # @return [Hash] driver-specific properties
      def driver_props
        @config.driver_props
      end

      # Whether the initial connection URL specified multiple hosts.
      #
      # @return [Boolean]
      def multi_host_url?
        @config.driver_props[:host].to_s.include?(",")
      end

      # @return [Boolean] whether the driver is PostgreSQL
      def pg?
        driver_name == :postgresql
      end
    end
  end
end
