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

require_relative '../host/host_role'
require_relative '../host/host_availability'
require_relative '../logging'

module AwsAdvancedRubyDriverWrapper
  module Utils
    class RetryUtil
      include Logging

      SHORT_DELAY_SEC = 0.1
      DEFAULT_STRATEGY = 'random'

      Result = Data.define(:connection, :host_info)

      def initialize(service_container)
        @host_service = service_container.host_service
        @dialect_service = service_container.dialect_service
        @connection_service = service_container.connection_service
      end

      # Repeatedly refreshes the topology and attempts to open a connection to the current writer,
      # until one is established or the deadline passes.
      #
      # @param plugin_to_skip [Object] the plugin that should be skipped in the connect pipeline
      # @param plugin_manager [Services::PluginManager]
      # @param deadline [Time] the point in time at which to give up
      # @return [Result] the new connection and the host it was opened to
      # @raise [Timeout::Error] if no connection could be established before the deadline
      def connect_to_writer(plugin_to_skip, plugin_manager, deadline:)
        connect_to_allowed_host(plugin_to_skip, plugin_manager, verify_role: Host::HostRole::WRITER, deadline: deadline) do |allowed_hosts|
          writer_candidate = @host_service.all_hosts.find { |h| h.role == Host::HostRole::WRITER }

          if writer_candidate.nil?
            logger.debug { 'No writer host found in topology' }
            nil
          elsif allowed_hosts.none? { |h| h.host_and_port == writer_candidate.host_and_port }
            logger.debug { "New writer not in allowed hosts: #{writer_candidate.url}" }
            nil
          else
            [writer_candidate]
          end
        end
      end

      # Repeatedly refreshes the topology and attempts to open a connection to one of the hosts
      # selected by the given block, until one is established or the deadline passes.
      #
      # Hosts that cannot be connected to, or whose role does not match +verify_role+, are dropped
      # from the candidate list. Once every candidate has been ruled out, the topology is refreshed
      # and the block is consulted again.
      #
      # @param plugin_to_skip [Object] the plugin that should be skipped in the connect pipeline
      # @param plugin_manager [Services::PluginManager]
      # @param deadline [Time] the point in time at which to give up
      # @param verify_role [Symbol, nil] the role the new connection must report, or nil to accept any host
      # @param strategy [String] the host selection strategy used to order the candidates
      # @yieldparam allowed_hosts [Array<Host::HostInfo>] the current allowed hosts
      # @yieldreturn [Array<Host::HostInfo>, nil] the hosts to attempt, or nil/empty to refresh and retry
      # @return [Result] the new connection and the host it was opened to
      # @raise [Timeout::Error] if no connection could be established before the deadline
      def connect_to_allowed_host(plugin_to_skip, plugin_manager, deadline:, verify_role: nil, strategy: DEFAULT_STRATEGY)
        strategy = DEFAULT_STRATEGY if strategy.nil? || strategy.to_s.empty?

        loop do
          break if Time.now >= deadline

          # The roles in this list might not be accurate, depending on whether the new topology has become available yet.
          @host_service.refresh_host_list
          candidates = yield(@host_service.hosts)

          if candidates.nil? || candidates.empty?
            sleep(SHORT_DELAY_SEC)
            next
          end

          # Copy the candidates and mark them available so that the selection strategy considers all of them.
          remaining = candidates.map do |host|
            host.deep_dup.tap { |dup| dup.availability = Host::HostAvailability::AVAILABLE }
          end

          while !remaining.empty? && Time.now < deadline
            candidate = select_candidate(remaining, verify_role, strategy)
            if candidate.nil?
              logger.debug { "Unable to find #{verify_role || 'a host'} in the updated host list: #{remaining.map(&:url)}" }
              sleep(SHORT_DELAY_SEC)
              break # Give up on this candidate list and refresh the topology.
            end

            result = attempt_connection(candidate, verify_role, plugin_to_skip, plugin_manager)
            return result if result

            remaining.delete(candidate)
          end
        end

        raise Timeout::Error, 'Not able to establish a connection before timing out'
      end

      private

      # @return [Result, nil] the result, or nil if the connection failed or reported the wrong role
      def attempt_connection(candidate, verify_role, plugin_to_skip, plugin_manager)
        conn = plugin_manager.connect(candidate, @connection_service.driver_props, false, plugin_to_skip: plugin_to_skip)

        # Since the roles in the host list might not be accurate, we execute a query to check the instance's role.
        role = verify_role.nil? ? nil : @dialect_service.db_dialect.host_role(conn)
        if verify_role.nil?
          return Result.new(conn, candidate)
        elsif verify_role == role
          return Result.new(conn, candidate.deep_dup(role: role))
        end

        # The role is not the one that was asked for, so the connection is not valid.
        close_quietly(conn)
        nil
      rescue StandardError => e
        logger.debug { "Exception connecting to #{candidate.host}: #{e.message}" }
        close_quietly(conn)
        nil
      end

      def select_candidate(hosts, role, strategy)
        @host_service.select_host(hosts, role, strategy)
      rescue StandardError
        nil
      end

      def close_quietly(conn)
        return if conn.nil?

        @dialect_service.driver_dialect.close_connection(conn)
      rescue StandardError
        # ignore
      end
    end
  end
end
