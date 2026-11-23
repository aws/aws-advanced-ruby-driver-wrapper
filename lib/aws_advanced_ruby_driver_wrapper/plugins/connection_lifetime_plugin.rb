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
require_relative '../errors'
require_relative '../logging'
require_relative '../property_definition'
require_relative '../ruby_method'

module AwsAdvancedRubyDriverWrapper
  module Plugins
    # Limits how long a connection is used. Once a connection reaches +connection_lifetime_sec+, the
    # next call that would reach the database either replaces it with a new connection to the host
    # the application configured (+reconnect+) or closes it for good (+close+).
    #
    # The age is only checked when such a call is made, so an idle connection is not touched until it
    # is used again. A connection inside a transaction is left alone until the transaction ends.
    class ConnectionLifetimePlugin
      include Logging

      ACTIONS = {
        'reconnect' => :reconnect,
        'close' => :close
      }.freeze

      # Calls that release the connection or what was read through it. Failing these would leave the
      # application unable to clean up a connection that is being retired.
      RELEASE_METHODS = Set[
        RubyMethod::CONNECTION_CLOSE.name,
        RubyMethod::STATEMENT_CLOSE.name,
        RubyMethod::RESULT_FREE.name
      ].freeze

      # Calls that reopen the physical connection in place. Active Record's PostgreSQL adapter
      # recovers a connection it was told is broken by resetting it, so these are never refused, and
      # a connection that is open again afterwards starts a new lifetime.
      REOPEN_METHODS = Set[
        RubyMethod::CONNECTION_RESET.name,
        RubyMethod::CONNECTION_RESET_START.name,
        RubyMethod::CONNECTION_RESET_POLL.name
      ].freeze

      MONOTONIC_CLOCK = -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) }

      attr_reader :subscribed_methods

      # @param clock [#call] returns the current time in seconds from a monotonic source
      # @raise [Errors::AwsError] if +connection_lifetime_sec+ or +connection_lifetime_action+ is invalid
      def initialize(service_container, props = ::Concurrent::Map.new, clock: MONOTONIC_CLOCK)
        @service_container = service_container
        @clock = clock
        @lifetime_sec = self.class.lifetime_sec(props)
        @action = self.class.action(props)

        network_methods = service_container.dialect_service.driver_dialect.network_bound_methods
        @subscribed_methods = (Set[RubyMethod::CONNECT.name] | (network_methods - RELEASE_METHODS)).freeze
        @reopen_methods = REOPEN_METHODS & network_methods

        # Keyed by the connection object itself: two driver connections never compare equal by
        # identity, whatever their own #== says.
        @creation_times = {}.compare_by_identity
        @original_host_info = nil
        @timed_connection = nil
        @timed_connection_created_at = nil
        @terminal = false
      end

      # @return [Float] the configured lifetime in seconds
      # @raise [Errors::AwsError] unless the property holds a positive number
      def self.lifetime_sec(props)
        value = PropertyDefinition::CONNECTION_LIFETIME_SEC.get(props)
        seconds = Float(value, exception: false) if value.is_a?(Numeric) || value.is_a?(String)
        return seconds if seconds&.finite? && seconds.positive?

        raise Errors::AwsError,
              "#{PropertyDefinition::CONNECTION_LIFETIME_SEC.name} is required and must be a positive number of seconds. " \
              "Received: #{value.inspect}"
      end

      # @return [Symbol] +:reconnect+ or +:close+
      # @raise [Errors::AwsError] for any other value
      def self.action(props)
        value = PropertyDefinition::CONNECTION_LIFETIME_ACTION.get(props)
        action = ACTIONS[value.to_s.strip.downcase]
        return action if action

        raise Errors::AwsError,
              "#{PropertyDefinition::CONNECTION_LIFETIME_ACTION.name} must be one of #{ACTIONS.keys.join(', ')}. " \
              "Received: #{value.inspect}"
      end

      def connect(host_info, _driver_props, is_initial_connection, pipeline_callable)
        # The host the application asked for, before any plugin further down the chain replaces it
        # with a host chosen from the topology. A replacement connection goes back to it, so that the
        # endpoint's own routing picks the instance again.
        @original_host_info ||= host_info if is_initial_connection

        conn = pipeline_callable.call
        @creation_times[conn] = @clock.call unless conn.nil?
        conn
      end

      def execute(method_name, pipeline_callable, *, **, &)
        return reopen(pipeline_callable) if @reopen_methods.include?(method_name)
        raise Errors::ConnectionLifetimeError if @terminal
        return pipeline_callable.call unless current_connection_expired?

        if in_transaction?
          logger.debug do
            'The connection has reached its maximum lifetime, but a transaction is open. ' \
              "Running #{method_name} on the current connection and acting once the transaction ends."
          end
          return pipeline_callable.call
        end

        @action == :close ? close_current_connection : reconnect
      end

      private

      def connection_service
        @service_container.connection_service
      end

      def driver_dialect
        @service_container.dialect_service.driver_dialect
      end

      # The driver's own report comes first: the tracked state is only updated once a call returns,
      # so it is stale for the first statement run inside a pg +transaction+ block.
      def in_transaction?
        reported = driver_dialect.reported_in_transaction(connection_service.current_connection)
        return reported unless reported.nil?

        @service_container.session_state_service&.in_transaction? || false
      end

      def reopen(pipeline_callable)
        pipeline_callable.call
      ensure
        conn = connection_service.current_connection
        unless conn.nil? || connection_closed?(conn)
          @terminal = false
          forget_closed_connections
          @timed_connection = conn
          @timed_connection_created_at = @creation_times[conn] = @clock.call
        end
      end

      def current_connection_expired?
        conn = connection_service.current_connection
        return false if conn.nil?

        start_timing(conn) unless conn.equal?(@timed_connection)
        @clock.call - @timed_connection_created_at >= @lifetime_sec
      end

      # A connection that was not opened through this plugin, for example one a plugin further down
      # the chain swapped in, is timed from the moment it is first seen.
      def start_timing(conn)
        forget_closed_connections
        @timed_connection = conn
        @timed_connection_created_at = (@creation_times[conn] ||= @clock.call)
      end

      def close_current_connection
        @terminal = true
        conn = connection_service.current_connection
        logger.debug { 'The connection has reached its maximum lifetime. Closing it.' }
        driver_dialect.close_connection(conn)
        @creation_times.delete(conn)
        raise Errors::ConnectionLifetimeError
      end

      # Opens a connection to the original host and makes it the current one. The call that found the
      # connection expired is not run: it raises ConnectionLifetimeSuccessError, so that the
      # application, which may have set session state on the old connection, decides whether to retry.
      def reconnect
        previous = connection_service.current_connection
        replacement = nil

        begin
          host_info = @original_host_info
          raise Errors::AwsError, 'The original host of the connection is unknown, so it cannot be replaced.' if host_info.nil?

          logger.debug { "The connection has reached its maximum lifetime. Reconnecting to #{host_info.host_and_port}." }
          replacement = @service_container.plugin_manager.connect(host_info, connection_service.driver_props, false, plugin_to_skip: self)
          raise Errors::AwsError, 'The reconnect attempt did not return a connection.' if replacement.nil?

          created_at = @clock.call
          unless connection_service.current_connection.equal?(replacement)
            connection_service.update_current_connection(replacement, host_info)
          end
        rescue StandardError
          clean_up_failed_replacement(replacement, previous)
          raise Errors::ConnectionLifetimeFailedError
        end

        @creation_times[replacement] = created_at
        @timed_connection = replacement
        @timed_connection_created_at = created_at
        forget_closed_connections
        raise Errors::ConnectionLifetimeSuccessError
      end

      # Opening a connection makes it the current one as soon as the driver returns it, so a failure
      # after that point, such as an error from the connection init callback, has already replaced and
      # closed the previous connection. Neither is in a state the application expects, so both are
      # closed and the plugin stops serving calls.
      def clean_up_failed_replacement(replacement, previous)
        current = connection_service.current_connection
        if !current.nil? && !current.equal?(previous)
          @terminal = true
          close_and_forget(current)
          close_and_forget(previous)
        elsif !replacement.nil? && !replacement.equal?(current)
          close_and_forget(replacement)
        end
      end

      def close_and_forget(conn)
        return if conn.nil?

        @creation_times.delete(conn)
        driver_dialect.close_connection(conn)
      end

      # Drops the creation times of connections that have been closed, which is every connection the
      # current one replaced, so the map holds only connections that can still be used.
      def forget_closed_connections
        @creation_times.delete_if { |conn, _| connection_closed?(conn) }
      end

      def connection_closed?(conn)
        driver_dialect.closed?(conn)
      rescue StandardError
        # A connection that cannot report its state cannot be used either.
        true
      end
    end
  end
end
