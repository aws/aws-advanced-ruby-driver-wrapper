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
        @failover_reader_host_selector_strategy = FAILOVER_READER_HOST_SELECTOR_STRATEGY.get(props)
        @failover_mode = nil
        @rds_url_type = nil

        @closed_explicitly = false
        @is_closed = false
        @is_in_transaction = false
        @last_error_dealt_with = nil
        @writer_host_info = nil

        network_methods = @service_container.dialect_service.driver_dialect.network_bound_methods
        @subscribed_methods = (SUBSCRIBED_METHODS | network_methods).freeze
      end

      attr_reader :subscribed_methods

      def connect(host_info, props, is_initial_connection, pipeline_callable)
        init_failover_mode

        conn = nil
        unless ENABLE_CONNECT_FAILOVER.get_bool(@props)
          conn = get_verified_connection(is_initial_connection, host_info, props, pipeline_callable)
          raise Errors::AwsError, 'Unable to establish a SQL connection due to an unexpected error' if conn.nil?

          return conn
        end

        host_service = @service_container.host_service
        topology_host = host_service.hosts.find { |h| h.host_and_port == host_info&.host_and_port }

        if !topology_host.nil? && topology_host.availability == Host::HostAvailability::UNAVAILABLE
          begin
            host_service.refresh_host_list
            failover
          rescue Errors::FailoverSuccessError => _e
            conn = connection_service.current_connection
          end

          host_service.refresh_host_list if is_initial_connection
          return conn
        end

        begin
          conn = get_verified_connection(is_initial_connection, host_info, props, pipeline_callable)
        rescue StandardError => e
          raise unless should_error_trigger_connection_switch?(e)

          host_service.set_availability(host_info, Host::HostAvailability::UNAVAILABLE)
          begin
            failover
          rescue Errors::FailoverSuccessError
            conn = connection_service.current_connection
          end
        end

        host_service.refresh_host_list if is_initial_connection
        conn
      end

      def execute(method_name, pipeline_callable, ...)
        if connection_service.current_connection && !can_direct_execute?(method_name) &&
           !@closed_explicitly && driver_dialect.closed?(connection_service.current_connection)
          pick_new_connection
        end

        if can_direct_execute?(method_name)
          @closed_explicitly = true if method_name == RubyMethod::CONNECTION_CLOSE.name
          return pipeline_callable.call(...)
        end

        handle_invalid_invocation_on_closed_connection if @is_closed && !allowed_on_closed_connection?(method_name)

        begin
          pipeline_callable.call(...)
        rescue StandardError => e
          deal_with_original_error(e)
        end
      end

      private

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

      def failover_enabled?
        @rds_url_type != Utils::RdsUrlType::RDS_PROXY &&
          @rds_url_type != Utils::RdsUrlType::RDS_PROXY_ENDPOINT &&
          !host_service.all_hosts.empty?
      end

      def can_direct_execute?(method_name)
        method_name == RubyMethod::CONNECTION_CLOSE.name ||
          method_name == RubyMethod::CONNECTION_PING.name # TODO: should we keep or remove this line?
      end

      def allowed_on_closed_connection?(method_name)
        can_direct_execute?(method_name)
      end

      def handle_invalid_invocation_on_closed_connection
        if @closed_explicitly
          raise Errors::AwsError.new(
            'No operations allowed after connection closed.',
            connection_broken: true
          )
        else
          @is_closed = false
          pick_new_connection
        end
      end

      def deal_with_original_error(error)
        logger.debug { "Detected error: #{error.message}" }
        raise error if @last_error_dealt_with == error || !should_error_trigger_connection_switch?(error)

        invalidate_current_connection
        host_service.set_availability(
          connection_service.current_host_info,
          Host::HostAvailability::UNAVAILABLE
        )
        pick_new_connection
        @last_error_dealt_with = error
        raise error
      end

      def should_error_trigger_connection_switch?(error)
        unless failover_enabled?
          logger.debug { 'Failover is disabled' }
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
          @is_in_transaction = true
          begin
            driver_dialect.execute('ROLLBACK')
          rescue StandardError
            nil
          end
        end

        begin
          driver_dialect.close_connection(conn) unless driver_dialect.closed?(conn)
        rescue StandardError
          # ignore
        end
      end

      def pick_new_connection
        if @is_closed && @closed_explicitly
          logger.debug { 'Connection was explicitly closed, skipping failover' }
          return
        end

        failover
      end

      def failover
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
          connection_service.update_current_connection(result.connection, result.host_info)
        rescue Timeout::Error
          raise Errors::FailoverFailedError, 'Unable to connect to a reader instance'
        end

        logger.info { "Established connection to: #{connection_service.current_host_info}" }
        raise_failover_success_error
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

          result = retry_util.connect_to_writer(
            @service_container,
            @props,
            self,
            deadline: failover_deadline
          )

          if result&.connection && result.host_info
            connection_service.update_current_connection(result.connection, result.host_info)
            # TODO: is there a cleaner way of doing this?
            result.connection = nil # Prevents connection from closing in the ensure block
            logger.debug { "Established connection to: #{connection_service.current_host_info}" }
            raise_failover_success_error
          end
        rescue Timeout::Error
          raise Errors::FailoverFailedError
        ensure
          duration_ms = ((Time.now - failover_start) * 1000).round
          logger.debug { "Writer failover duration: #{duration_ms}ms" }

          close_conn(result.connection) if result&.connection && result.connection != connection_service.current_connection
        end
      end

      def raise_failover_success_error
        raise Errors::FailoverSuccessError unless @is_in_transaction || @service_container.session_state_service.in_transaction?

        @service_container.session_state_service.in_transaction = false
        raise Errors::TransactionStateUnknownError
      end

      def get_reader_failover_connection(deadline)
        original_writer = nil
        original_writer_still_writer = false
        need_delay = false

        loop do
          sleep(0.1) if need_delay
          need_delay = true

          # the roles in this list might not be accurate, depending on whether the new topology has become available yet
          hosts = host_service.hosts
          reader_candidates = hosts.select { |h| h.role == Host::HostRole::READER }

          if original_writer.nil?
            host_list_writer = hosts.find { |h| h.role == Host::HostRole::WRITER }
            if host_list_writer
              original_writer = host_list_writer
              original_writer_still_writer = false
            end
          end

          remaining_readers = reader_candidates.dup
          while !remaining_readers.empty? && Time.now < deadline
            reader_candidate = select_reader_candidate(remaining_readers)

            if reader_candidate.nil?
              # assume all readers are available and try them all
              available_readers = remaining_readers.map do |h|
                h.deep_dup.tap { |dup| dup.availability = Host::HostAvailability::AVAILABLE }
              end
              reader_candidate = select_reader_candidate(available_readers)
            end

            if reader_candidate.nil?
              logger.debug { 'Unable to find reader in updated host list' }
              break
            end

            candidate_conn = nil
            begin
              candidate_conn = @service_container.plugin_manager.connect(reader_candidate, @props, false, plugin_to_skip: self)
              # Since the roles in the host list might not be accurate, we execute a query to check the instance's role.
              role = db_dialect.host_role(candidate_conn)
              if role == Host::HostRole::READER || @failover_mode != FailoverMode::STRICT_READER
                updated_host = reader_candidate.deep_dup.tap { |h| h.role = role }
                result = ReaderFailoverResult.new(candidate_conn, updated_host)
                # TODO: is there a cleaner way of doing this?
                candidate_conn = nil # Prevents connection from closing in the ensure block
                return result
              end

              # The role is WRITER or UNKNOWN, and we are in STRICT_READER mode, so the connection is not valid.
              remaining_readers.delete(reader_candidate)
              close_conn(candidate_conn)
              candidate_conn = nil

              if role == Host::HostRole::WRITER
                # The reader candidate is actually a writer, which is not valid when @failover_mode is STRICT_READER.
                # We will remove it from the list of reader candidates to avoid retrying it in future iterations.
                reader_candidates.delete(reader_candidate)
              else
                logger.debug do
                  "Unable to determine host role for #{reader_candidate.url}. " \
                    'Since failover mode is set to STRICT_READER and the host may be a writer, ' \
                    'it will not be selected for reader failover.'
                end
              end
            rescue StandardError
              remaining_readers.delete(reader_candidate)
            ensure
              close_conn(candidate_conn)
            end
          end

          # We were not able to connect to any of the original readers. We will try connecting to the original writer,
          # which may have been demoted to a reader.
          if original_writer.nil? || Time.now >= deadline
            # No writer was found in the original topology, or we have timed out.
            next
          end

          if @failover_mode == FailoverMode::STRICT_READER && original_writer_still_writer
            # The original writer has been verified, so it is not valid when in STRICT_READER mode.
            next
          end

          candidate_conn = nil
          begin
            candidate_conn = @service_container.plugin_manager.connect(original_writer, @props, false, plugin_to_skip: self)
            role = db_dialect.host_role(candidate_conn)

            if role == Host::HostRole::READER || @failover_mode != FailoverMode::STRICT_READER
              updated_host = original_writer.deep_dup.tap { |h| h.role = role }
              result = ReaderFailoverResult.new(candidate_conn, updated_host)
              # TODO: is there a cleaner way of doing this?
              candidate_conn = nil # Prevents connection from closing in the ensure block
              return result
            end

            # The role is WRITER or UNKNOWN, and we are in STRICT_READER mode, so the connection is not valid.
            close_conn(candidate_conn)
            candidate_conn = nil

            if role == Host::HostRole::WRITER
              original_writer_still_writer = true
            else
              logger.debug do
                "Unable to determine host role for #{original_writer.url}. " \
                  'Since failover mode is set to STRICT_READER and the host may be a writer, ' \
                  'it will not be selected for reader failover.'
              end
            end
          rescue StandardError
            logger.debug { "Failed to connect to host: #{original_writer.url}" }
          ensure
            close_conn(candidate_conn)
          end

          break if Time.now >= deadline
        end

        raise Timeout::Error, 'The reader failover process was not able to establish a connection before timing out.'
      end

      def select_reader_candidate(hosts)
        host_service.select_host(
          hosts,
          Host::HostRole::READER,
          @failover_reader_host_selector_strategy
        )
      rescue StandardError
        nil
      end

      def get_verified_connection(is_initial_connection, host_info, props, connect_func)
        url_type = Utils::RdsUtils.identify_rds_type(host_info&.host)

        unless [Utils::RdsUrlType::RDS_WRITER_CLUSTER, Utils::RdsUrlType::RDS_GLOBAL_WRITER_CLUSTER].include?(url_type)
          # It's not a writer cluster endpoint. Continue with a normal workflow.
          return connect_func.call
        end

        if url_type == Utils::RdsUrlType::RDS_WRITER_CLUSTER
          writer = host_service.all_hosts.find { |h| h.role == Host::HostRole::WRITER }
          # Continue with the regular workflow if no writer was found.
          # This may occur with the first connection when topology isn't yet available.
          return connect_func.call unless writer && Utils::RdsUtils.rds_instance?(writer.host)
        end

        conn = connect_func.call
        connected_to_reader = db_dialect.host_role(conn) == Host::HostRole::READER
        if connected_to_reader
          # The writer cluster URL resolved to a reader. The topology must be outdated, so we should force a refresh.
          host_service.force_refresh_host_list(verify_writer: false, timeout_sec: 5.0)
        else
          host_service.refresh_host_list
        end

        if @writer_host_info.nil?
          writer_candidate = host_service.all_hosts
                                         .find { |h| h.role == Host::HostRole::WRITER }
          if writer_candidate && Utils::RdsUtils.rds_cluster_dns?(writer_candidate.host)
            # Topology has not resolved to instance-level DNS — stale DNS detection
            # cannot be performed (no instance IP to compare against).
            if connected_to_reader
              # Stale DNS: cluster writer endpoint resolved to a reader node.
              # Close the bad connection and throw so the connection pool retries.
              close_conn(conn)
              logger.debug { "Stale DNS detected. Opening a connection to #{writer_candidate}" }

              # The caller will handle this result and retry or fail
              return nil
            end

            # Connected to a writer - the connection is valid and topology info is just lagging
            return conn
          end
          @writer_host_info = writer_candidate
        end

        return conn if @writer_host_info.nil?

        logger.debug { "Writer host: #{@writer_host_info}" }

        if connected_to_reader
          # Reconnect to writer host if current connection is reader
          logger.debug { "Stale DNS data detected. Opening a connection to #{@writer_host_info}" }

          allowed_hosts = host_service.hosts
          unless allowed_hosts.any? { |h| h.host_and_port == @writer_host_info&.host_and_port }
            raise Errors::AwsError, "Current writer #{@writer_host_info&.host_and_port} is not in allowed hosts"
          end

          writer_conn = @service_container.plugin_manager.connect(@writer_host_info, props, false, plugin_to_skip: self)
          connection_service.initial_host_info = @writer_host_info if is_initial_connection

          close_conn(conn)
          return writer_conn
        end

        conn
      end

      def close_conn(conn)
        return if conn.nil?

        driver_dialect.close_connection(conn)
      rescue StandardError
        # ignore
      end
    end
  end
end
