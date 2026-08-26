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

require 'concurrent/map'
require_relative '../host/random_host_selector'

module AwsRubyDriverWrapper
  module Services
    class HostService
      DEFAULT_HOST_SELECTORS = {
        Host::RandomHostSelector::STRATEGY_NAME => Host::RandomHostSelector.new
      }.freeze

      attr_accessor :host_list_provider

      @host_id_cache = Concurrent::Map.new
      @strategies = Concurrent::Map.new
      DEFAULT_HOST_SELECTORS.each { |name, selector| @strategies[name] = selector }

      def initialize(service_container)
        @service_container = service_container
        @all_hosts = []
        @availability_cache = Utils::Storage::ExpirationCache.new
        @host_list_provider = nil
      end

      class << self
        attr_reader :host_id_cache

        def clear_id_cache
          @host_id_cache.clear
        end

        # Register a non-default host selector. The selector is shared by every HostService in the process,
        # so it must be safe to call from multiple threads.
        #
        # @param name [String] strategy name
        # @param selector [#select_host] any object responding to select_host(hosts, role, props)
        def register_host_selector(name, selector)
          raise Errors::AwsError, "Cannot override default host selection strategy: '#{name}'" if DEFAULT_HOST_SELECTORS.key?(name)

          @strategies[name] = selector
        end

        # @param name [String] strategy name
        # @return [#select_host, nil] the registered selector, or nil if the name is unknown
        def host_selector(name)
          @strategies[name]
        end

        # Removes every non-default host selector. For testing only.
        # @api private
        def reset_host_selectors
          # Snapshot the names first rather than iterating the map while deleting from it.
          custom_names = @strategies.keys.reject { |name| DEFAULT_HOST_SELECTORS.key?(name) }
          custom_names.each { |name| @strategies.delete(name) }
        end
      end

      # @param hosts [Array<Host::HostInfo>]
      # @param role [Symbol, nil]
      # @param strategy [String]
      # @param props [Hash, nil]
      # @return [Host::HostInfo]
      def select_host(hosts, role, strategy, props = nil)
        selector = self.class.host_selector(strategy)
        raise Errors::AwsError, "Unsupported host selection strategy: '#{strategy}'" if selector.nil?

        selector.select_host(hosts, role, props)
      end

      # @return [Array<Host::HostInfo>] all hosts in the topology, including blocked/unavailable
      attr_reader :all_hosts

      # @return [Array<Host::HostInfo>] hosts filtered by allowed/blocked rules from the custom endpoint plugin
      def hosts
        rules = @service_container.storage_service.get_if_registered(
          :custom_endpoint_allowed_blocked,
          @service_container.connection_service.initial_host_info&.url,
          register_access: false
        )
        return @all_hosts if rules.nil?

        allowed = rules[:allowed]
        blocked = rules[:blocked]
        required_role = rules[:required_role]

        hosts = @all_hosts
        hosts = hosts.select { |h| allowed.include?(h.id) } if allowed
        hosts = hosts.reject { |h| h.id && blocked.include?(h.id) } if blocked
        hosts = hosts.select { |h| h.role == required_role } if required_role
        hosts
      end

      # Updates the availability of a host in the internal host list.
      #
      # @param host_info [HostInfo] the host whose availability has been determined
      # @param availability [Symbol] the new availability status, e.g. :available or :unavailable
      def set_availability(host_info, availability)
        host = @all_hosts.find { |h| h.id == host_info.id || h.host.casecmp?(host_info.host) }
        return if host.nil?

        host.availability = availability
        @availability_cache.put(host_info.url, availability)
      end

      # Refresh the host list from the host list provider.
      def refresh_host_list
        updated_hosts = @host_list_provider&.refresh
        return if updated_hosts.nil? || updated_hosts == @all_hosts

        apply_cached_availability(updated_hosts)
        @all_hosts = updated_hosts
      end

      # Force a refresh of the host list, bypassing any caching.
      #
      # @param verify_writer [Boolean]
      # @param timeout_sec [Float]
      # @return [Boolean] whether the refresh was successful
      def force_refresh_host_list?(verify_writer: false, timeout_sec: 5.0)
        updated_hosts = @host_list_provider&.force_refresh(verify_writer, timeout_sec)
        return false if updated_hosts.nil?

        if updated_hosts != @all_hosts
          apply_cached_availability(updated_hosts)
          @all_hosts = updated_hosts
        end

        true
      end

      # Identify which host in the topology a given connection belongs to.
      #
      # @param connection [Object]
      # @param connection_host_info [Host::HostInfo, nil] the host info used to establish the connection
      # @return [Host::HostInfo, nil]
      def identify_host(connection, connection_host_info = nil)
        return find_host(*query_id_and_name(connection)) if connection_host_info.nil?

        url_type = Utils::RdsUtils.identify_rds_type(connection_host_info&.host)
        case url_type
        when Utils::RdsUrlType::RDS_INSTANCE
          connection_host_info
        when Utils::RdsUrlType::IP_ADDRESS, Utils::RdsUrlType::OTHER
          get_cached_host_info(connection, connection_host_info)
        else
          find_host(*query_id_and_name(connection))
        end
      end

      private

      def apply_cached_availability(hosts)
        hosts.each do |host|
          availability = @availability_cache.get(host.url)
          next if availability.nil?

          host.availability = availability
        end
      end

      def get_cached_host_info(connection, connection_host_info)
        host = connection_host_info.host
        instance_id, instance_name = self.class.host_id_cache.compute_if_absent(host) do
          query_id_and_name(connection)
        end
        find_host(instance_id, instance_name)
      end

      def query_id_and_name(connection)
        @service_container.dialect_service.db_dialect.instance_identity(connection)
      rescue StandardError
        [nil, nil]
      end

      def find_host(instance_id, instance_name)
        topology = @host_list_provider&.refresh
        return nil if topology.nil? || topology.empty?

        topology.find { |h| h.id == instance_id || h.host == instance_name }
      end
    end
  end
end
