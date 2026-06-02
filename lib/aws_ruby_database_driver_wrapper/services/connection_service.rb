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

require 'monitor'
require_relative '../utils/host_list_utils'

module AwsRubyDatabaseDriverWrapper
  module Services
    class ConnectionService
      attr_reader :current_connection, :config

      # @param config [Utils::ConnectionConfig] the parsed connection configuration
      def initialize(service_container, config)
        @service_container = service_container
        @config = config
        @current_connection = nil
        @current_host_info = config.initial_host_info
        @connection_switch_lock = Monitor.new
      end

      # @return [Host::HostInfo, nil] host info for the current connection
      def current_host_info
        return @current_host_info if @current_host_info

        @current_host_info = @config.initial_host_info
        return @current_host_info if @current_host_info

        host_service = @service_container.host_service
        hosts = host_service.all_hosts
        raise Errors::AwsError, 'Attempted to access the current host list, but the host list is empty' if host_service.all_hosts.empty?

        @current_host_info = Utils::HostListUtils.writer(hosts)
        allowed_hosts = host_service.hosts
        if @current_host_info && !Utils::HostListUtils.contains_url?(allowed_hosts, @current_host_info.url)
          raise Errors::AwsError,
                'Current host is not in the list of allowed hosts: ' \
                "current_host=#{@current_host_info.url}, " \
                "allowed_hosts=#{Utils::HostListUtils.to_host_urls_s(allowed_hosts)}"
        end

        @current_host_info = hosts[0] if @current_host_info.nil? && hosts.any?

        if @current_host_info.nil?
          raise Errors::AwsError,
                'Unable to identify a current host from the available host list'
        end

        @current_host_info
      end

      # @param connection [Object] the new connection
      # @param host_info [Host::HostInfo] host info for the new connection
      def update_current_connection(connection, host_info)
        @connection_switch_lock.synchronize do
          @current_connection = connection
          @current_host_info = host_info
          @service_container.session_state_service.reset
        end
      end

      # @return [Symbol] the driver name, e.g. :postgresql or :mysql2
      def driver_name
        @config.driver_name
      end

      # @return [Hash] wrapper-specific properties
      def wrapper_props
        @config.wrapper_props
      end

      # @return [Host::HostInfo, nil] the initial host info from config
      def initial_host_info
        @config.initial_host_info
      end

      # @return [Hash{String => Hash}] prefixed props keyed by prefix (already stripped)
      def prefixed_props
        @config.prefixed_props
      end

      # @return [Hash] driver-specific properties
      def driver_props
        @config.driver_props
      end

      # Whether the initial connection URL specified multiple hosts.
      #
      # @return [Boolean]
      def multi_host_url?
        @config.driver_props[:host].to_s.include?(',')
      end

      # @return [Boolean] whether the driver is PostgreSQL
      def pg?
        driver_name == :postgresql
      end
    end
  end
end
