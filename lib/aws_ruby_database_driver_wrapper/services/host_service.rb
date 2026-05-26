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

require_relative '../host/random_host_selector'

module AwsRubyDatabaseDriverWrapper
  module Services
    class HostService
      DEFAULT_HOST_SELECTORS = {
        Host::RandomHostSelector::STRATEGY_NAME => Host::RandomHostSelector.new
      }.freeze

      attr_accessor :host_list_provider

      def initialize(service_container)
        @service_container = service_container
        @strategies = DEFAULT_HOST_SELECTORS.dup
        @all_hosts = []
        @availability_cache = Utils::Storage::ExpirationCache.new
        @host_list_provider = nil
      end

      # Register a non-default host selector with the HostService (e.g. fastest_response).
      #
      # @param name [String] strategy name
      # @param selector [#select_host] any object responding to select_host(hosts, role, props)
      def register_host_selector(name, selector)
        raise Errors::AwsError, "Cannot override default host selection strategy: '#{name}'" if DEFAULT_HOST_SELECTORS.key?(name)

        @strategies[name] = selector
      end

      # @param hosts [Array<Host::HostInfo>]
      # @param role [Symbol, nil]
      # @param strategy [String]
      # @param props [Hash, nil]
      # @return [Host::HostInfo]
      def select_host(hosts, role, strategy, props = nil)
        selector = @strategies[strategy]
        raise Errors::AwsError, "Unsupported host selection strategy: '#{strategy}'" if selector.nil?

        selector.select_host(hosts, role, props)
      end

      # @return [Array<Host::HostInfo>] all hosts in the topology, including blocked/unavailable
      attr_reader :all_hosts

      # @return [Array<Host::HostInfo>] hosts filtered by allowed/blocked rules
      def hosts
        # Note: there will be no allowed/blocked rules until the custom endpoint plugin is implemented, so this method
        # just returns all hosts for now.
        @all_hosts
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
      # @param timeout_ms [Integer]
      # @return [Boolean] whether the refresh was successful
      def force_refresh_host_list(verify_writer: false, timeout_ms: 5000)
        updated_hosts = @host_list_provider&.force_refresh(verify_writer, timeout_ms)
        return if updated_hosts.nil? || updated_hosts == @all_hosts

        apply_cached_availability(updated_hosts)
        @all_hosts = updated_hosts
      end

      # Identify which host in the topology a given connection belongs to.
      #
      # @param connection [Object]
      # @return [Host::HostInfo, nil]
      def identify_host(connection)
        id = @service_container.dialect_service.db_dialect.query_host_id(connection)
        return nil if id.nil?

        hosts = @host_list_provider&.refresh
        hosts = @host_list_provider&.force_refresh if hosts.nil?

        return nil if hosts.nil?

        hosts.find { |host_info| host_info.id == id }
      end

      private

      def apply_cached_availability(hosts)
        hosts.each do |host|
          availability = @availability_cache.get(host.url)
          next if availability.nil?

          host.availability = availability
        end
      end
    end
  end
end
