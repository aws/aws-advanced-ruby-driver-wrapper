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
require_relative '../host/host_info'
require_relative '../host/host_role'
require_relative '../host/host_availability'
require_relative '../logging'
require_relative '../utils/rds_utils'
require_relative '../utils/rds_url_type'
require_relative '../utils/retry_util'
require_relative '../wrapper_property'
require_relative 'failover_mode'

module AwsRubyDatabaseDriverWrapper
  module Plugins
    class FailoverPlugin
      include Logging

      DefaultPlugin::SUBSCRIBED_METHODS = Set['connect'].freeze
      ReaderFailoverResult = Data.define(:connection, :host_info)

      def initialize(service_container, props = ::Concurrent::Map.new)
        @service_container = service_container
        @props = props

        @failover_timeout = FAILOVER_TIMEOUT.get_int(props)
        @reader_selector_strategy = FAILOVER_READER_HOST_SELECTOR_STRATEGY.get(props)
        @failover_mode = nil
        @rds_url_type = nil

        @closed_explicitly = false
        @last_handled_error = nil

        network_methods = @service_container.dialect_service.driver_dialect.network_bound_methods
        @subscribed_methods = (SUBSCRIBED_METHODS | network_methods).freeze
      end

      attr_reader :subscribed_methods

      def connect(host_info, props, is_initial_connection, pipeline_callable)
        init_failover_mode

        unless ENABLE_CONNECT_FAILOVER.get_bool(@props)
          return get_verified_connection(is_initial_connection, host_info, props, pipeline_callable)
        end

        topology_host = host_service.hosts.find { |h| h.host_and_port == host_info&.host_and_port }

        if !topology_host.nil? && topology_host.availability == Host::HostAvailability::UNAVAILABLE
          host_service.refresh_host_list
          return connect_via_failover(is_initial_connection)
        end

        begin
          conn = get_verified_connection(is_initial_connection, host_info, props, pipeline_callable)
          host_service.refresh_host_list if is_initial_connection
          conn
        rescue StandardError => e
          raise unless trigger_failover?(e)

          host_service.set_availability(host_info, Host::HostAvailability::UNAVAILABLE)
          connect_via_failover(is_initial_connection)
        end
      end

      def execute(method_name, pipeline_callable, ...)
        if can_direct_execute?(method_name)
          @closed_explicitly = true if method_name == RubyMethod::CONNECTION_CLOSE.name
          return pipeline_callable.call(...)
        end

        conn = connection_service.current_connection
        if conn && !@closed_explicitly && driver_dialect.closed?(connection_service.current_connection)
          logger.warn("#{method_name} was called on closed connection #{conn} to #{connection_service.current_host_info}." \
                      'The driver will attempt to failover and then execute.')
          failover
        end

        begin
          pipeline_callable.call(...)
        rescue StandardError => e
          handle_error(e)
        end
      end

      private

      def connect_via_failover(is_initial_connection)
        begin
          failover
        rescue Errors::FailoverSuccessError => _e
          conn = connection_service.current_connection
        end

        host_service.refresh_host_list if is_initial_connection
        conn
      end

      def connection_service
        @service_container.connection_service
      end

      def host_service
        @service_container.host_service
      end

      def dialect_service
        @service_container.dialect_service
      end

      def driver_dialect
        dialect_service.driver_dialect
      end

      def db_dialect
        dialect_service.db_dialect
      end

      def init_failover_mode
        return unless @rds_url_type.nil?

        @failover_mode = FailoverMode.from_value(FAILOVER_MODE.get(@props))
        initial_host = connection_service.initial_host_info
        @rds_url_type = Utils::RdsUtils.identify_rds_type(initial_host&.host)

        if @failover_mode.nil?
          @failover_mode = if @rds_url_type == Utils::RdsUrlType::RDS_READER_CLUSTER
                             FailoverMode::READER_OR_WRITER
                           else
                             FailoverMode::STRICT_WRITER
                           end
        end

        logger.debug { "failover_mode=#{@failover_mode}" }
      end

      def can_direct_execute?(method_name)
        method_name == RubyMethod::CONNECTION_CLOSE.name ||
          method_name == RubyMethod::CONNECTION_PING.name # TODO: should we keep or remove this line?
      end

      def handle_error(error)
        logger.debug { "Detected error: #{error.message}" }
        raise error if @last_handled_error == error || !trigger_failover?(error)

        invalidate_current_connection
        host_service.set_availability(
          connection_service.current_host_info,
          Host::HostAvailability::UNAVAILABLE
        )
        failover
        @last_handled_error = error
        raise error
      end

      def trigger_failover?(error)
        # TODO: should we throw an exception if the user tries to connect to RDS Proxy instead of checking here?
        if @rds_url_type != Utils::RdsUrlType::RDS_PROXY &&
           @rds_url_type != Utils::RdsUrlType::RDS_PROXY_ENDPOINT &&
           !host_service.all_hosts.empty?
          logger.debug do
            "Failover will be skipped for connection to #{connection_service.current_host_info}." \
              'Failover is skipped when connected to RDS Proxy or no topology information is available.'
          end
          return false
        end

        return true if dialect_service.network_error?(error)

        # initiate failover by returning true if failover mode is STRICT_WRITER and we got a read-only error.
        @failover_mode == FailoverMode::STRICT_WRITER && dialect_service.read_only_error?(error)
      end

      def invalidate_current_connection
        conn = connection_service.current_connection
        return if conn.nil?

        if @service_container.session_state_service.in_transaction?
          begin
            driver_dialect.execute('ROLLBACK')
          rescue StandardError
            nil
          end
        end

        close_quietly(conn)
      end

      def failover
        if @closed_explicitly
          logger.debug { 'Connection was explicitly closed, skipping failover' }
          return
        end

        if @failover_mode == FailoverMode::STRICT_WRITER
          failover_writer
        else
          failover_reader
        end
      end

      def failover_reader
        failover_start = Time.now
        failover_deadline = failover_start + @failover_timeout

        logger.info { 'Starting reader failover' }

        unless host_service.force_refresh_host_list(verify_writer: false, timeout_sec: 0)
          raise Errors::FailoverFailedError, 'The request to discover the new topology was unsuccessful'
        end

        begin
          result = get_reader_failover_connection(failover_deadline)
          was_in_transaction = @service_container.session_state_service.in_transaction?
          connection_service.update_current_connection(result.connection, result.host_info)
        rescue Timeout::Error
          raise Errors::FailoverFailedError, 'Unable to connect to a reader instance'
        end

        raise_failover_success_error(was_in_transaction)
      ensure
        duration_ms = ((Time.now - failover_start) * 1000).round
        logger.debug { "Reader failover duration: #{duration_ms}ms" }
      end

      def failover_writer
        failover_start = Time.now
        failover_deadline = failover_start + @failover_timeout
        retry_util = Utils::RetryUtil.new

        logger.info { 'Starting writer failover' }

        begin
          unless host_service.force_refresh_host_list(verify_writer: true, timeout_sec: @failover_timeout)
            raise Errors::FailoverFailedError, 'The request to discover the new topology timed out or was unsuccessful'
          end

          result = retry_util.connect_to_writer(@service_container, @props, self, deadline: failover_deadline)
          if result&.connection && result.host_info
            was_in_transaction = @service_container.session_state_service.in_transaction?
            connection_service.update_current_connection(result.connection, result.host_info)
            # TODO: is there a cleaner way of doing this?
            result = nil # Prevents connection from closing in the ensure block
            raise_failover_success_error(was_in_transaction)
          end
        rescue Timeout::Error
          raise Errors::FailoverFailedError
        ensure
          duration_ms = ((Time.now - failover_start) * 1000).round
          logger.debug { "Writer failover duration: #{duration_ms}ms" }
          close_quietly(result&.connection) if result&.connection != connection_service.current_connection
        end
      end

      def raise_failover_success_error(was_in_transaction)
        logger.debug { "Established connection to: #{connection_service.current_host_info}" }
        raise Errors::FailoverSuccessError unless was_in_transaction

        @service_container.session_state_service.in_transaction = false
        raise Errors::TransactionStateUnknownError
      end

      def get_reader_failover_connection(deadline)
        original_writer = nil
        original_writer_still_writer = false

        loop do
          break if Time.now >= deadline

          hosts = host_service.hosts
          reader_candidates = hosts.select { |h| h.role == Host::HostRole::READER }
          original_writer ||= hosts.find { |h| h.role == Host::HostRole::WRITER }

          result = try_reader_candidates(reader_candidates, deadline)
          return result if result

          result = try_original_writer(original_writer, original_writer_still_writer)
          case result
          when ReaderFailoverResult
            return result
          when :still_writer
            original_writer_still_writer = true
          end

          sleep(0.1)
        end

        raise Timeout::Error, 'The reader failover process was not able to establish a connection before timing out.'
      end

      def try_reader_candidates(reader_candidates, deadline)
        remaining = reader_candidates.dup

        while !remaining.empty? && Time.now < deadline
          candidate = select_reader_candidate(remaining)
          if candidate.nil?
            # Unable to find available candidate in the host list. Let's try assuming all hosts are available.
            available = remaining.map do |h|
              h.deep_dup.tap { |dup| dup.availability = Host::HostAvailability::AVAILABLE }
            end
            candidate = select_reader_candidate(available)
          end

          if candidate.nil?
            logger.debug { 'Unable to find reader in the updated host list.' }
            break
          end

          outcome, result = attempt_reader_connection(candidate)
          case outcome
          when :success
            return result
          when :writer
            reader_candidates.delete(candidate)
            remaining.delete(candidate)
          else
            remaining.delete(candidate)
          end
        end

        nil
      end

      def try_original_writer(original_writer, original_writer_still_writer)
        return nil if original_writer.nil?
        return nil if @failover_mode == FailoverMode::STRICT_READER && original_writer_still_writer

        outcome, result = attempt_reader_connection(original_writer)
        case outcome
        when :success
          result
        when :writer
          :still_writer
        else
          logger.debug { "Failed to connect to host: #{original_writer.url}" }
          nil
        end
      end

      def attempt_reader_connection(host_info)
        conn = @service_container.plugin_manager.connect(host_info, @props, false, plugin_to_skip: self)
        # Since the roles in the host list might not be accurate, we execute a query to check the instance's role.
        role = db_dialect.host_role(conn)

        if role == Host::HostRole::READER || @failover_mode != FailoverMode::STRICT_READER
          updated_host = host_info.deep_dup.tap { |h| h.role = role }
          return [:success, ReaderFailoverResult.new(conn, updated_host)]
        end

        # The role is WRITER or UNKNOWN, and we are in STRICT_READER mode, so the connection is not valid.
        close_quietly(conn)
        if role == Host::HostRole::WRITER
          [:writer, nil]
        else
          logger.debug do
            "Unable to determine host role for #{host_info.url}. " \
              'Since failover mode is set to STRICT_READER and the host may be a writer, ' \
              'it will not be selected for reader failover.'
          end
          [:unknown, nil]
        end
      rescue StandardError
        close_quietly(conn)
        [:failed, nil]
      end

      def select_reader_candidate(hosts)
        host_service.select_host(
          hosts,
          Host::HostRole::READER,
          @reader_selector_strategy
        )
      rescue StandardError
        nil
      end

      def get_verified_connection(is_initial_connection, host_info, props, connect_func)
        url_type = Utils::RdsUtils.identify_rds_type(host_info&.host)
        if url_type != Utils::RdsUrlType::RDS_WRITER_CLUSTER
          # We are not using a writer cluster endpoint. No verification needed - continue with the regular workflow.
          return connect_func.call
        end

        conn = connect_func.call
        if db_dialect.host_role(conn) == Host::HostRole::WRITER
          host_service.refresh_host_list
          return conn
        end

        # The writer cluster URL resolved to a reader. We will try to redirect to the writer instance.
        host_service.force_refresh_host_list(verify_writer: false, timeout_sec: 5.0)
        writer = host_service.all_hosts.find { |h| h.role == Host::HostRole::WRITER }
        if writer.nil? || Utils::RdsUtils.rds_cluster_dns?(writer.host)
          # Writer instance endpoint not found - unable to redirect.
          close_quietly(conn)
          raise Errors::AwsError, 'Stale DNS detected - a writer was requested, but the writer cluster endpoint resolved to a reader'
        end

        allowed_hosts = host_service.hosts
        unless allowed_hosts.any? { |h| h.host_and_port == writer.host_and_port }
          raise Errors::AwsError, "Current writer #{writer.host_and_port} is not in allowed hosts"
        end

        # Attempt to correct the stale DNS problem by connecting to the writer instance.
        logger.debug { "Stale DNS data detected. Opening a connection to #{writer.host}" }
        writer_conn = @service_container.plugin_manager.connect(writer, props, false, plugin_to_skip: self)
        connection_service.initial_host_info = writer if is_initial_connection

        # Close the incorrect reader connection.
        close_quietly(conn)
        writer_conn
      end

      def close_quietly(conn)
        return if conn.nil?

        driver_dialect.close_connection(conn)
      rescue StandardError
        # ignore
      end
    end
  end
end
