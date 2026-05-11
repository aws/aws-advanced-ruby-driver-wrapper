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

module AwsAdvancedRubyWrapper
  module Services
    class HostService
      DEFAULT_HOST_SELECTORS = {
        Host::RandomHostSelector::STRATEGY_NAME => Host::RandomHostSelector.new,
      }.freeze

      def initialize
        @strategies = DEFAULT_HOST_SELECTORS.dup
      end

      # Register a non-default host selector with the HostService (e.g. fastest_response).
      #
      # @param name [String] strategy name
      # @param selector [#select_host] any object responding to select_host(hosts, role, props)
      def register_host_selector(name, selector)
        if DEFAULT_HOST_SELECTORS.key?(name)
          raise Errors::AwsError, "Cannot override default host selection strategy: '#{name}'"
        end

        @strategies[name] = selector
      end

      # @param hosts [Array<Host::HostInfo>]
      # @param role [Symbol, nil]
      # @param strategy [String]
      # @param props [Hash, nil]
      # @return [Host::HostInfo]
      def select_host(hosts, role, strategy, props = nil)
        selector = @strategies[strategy]
        raise Errors::AwsError, "Unsupported host selection strategy: '#{strategy}'" unless selector

        selector.select_host(hosts, role, props)
      end

      # @return [Array<Host::HostInfo>] all hosts in the topology
      def all_hosts
        raise NotImplementedError
      end

      # @return [Array<Host::HostInfo>] hosts filtered by allowed/blocked rules
      def hosts
        raise NotImplementedError
      end

      # @param host_info [Host::HostInfo]
      # @param availability [Symbol] host availability status
      def set_availability(host_info, availability)
        raise NotImplementedError
      end

      # Refresh the host list from the host list provider.
      def refresh_host_list
        raise NotImplementedError
      end

      # Force a refresh of the host list, bypassing any caching.
      #
      # @param should_verify_writer [Boolean]
      # @param timeout_ms [Integer]
      # @return [Boolean] whether the refresh was successful
      def force_refresh_host_list(should_verify_writer: false, timeout_ms: 5000)
        raise NotImplementedError
      end

      # @return [Object] the current host list provider
      def host_list_provider
        raise NotImplementedError
      end

      # @param provider [Object]
      def host_list_provider=(provider)
        raise NotImplementedError
      end

      # Identify which host in the topology a given connection belongs to.
      #
      # @param connection [Object]
      # @return [Host::HostInfo, nil]
      def identify_host(connection)
        raise NotImplementedError
      end

      # Populate host aliases for the given connection.
      #
      # @param connection [Object, nil]
      # @param host_info [Host::HostInfo, nil]
      def fill_aliases(connection: nil, host_info: nil)
        raise NotImplementedError
      end

      # @param connection [Object]
      # @return [Symbol] the host role (:writer or :reader)
      def query_host_role(connection)
        raise NotImplementedError
      end
    end
  end
end
