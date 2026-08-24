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

require_relative '../../errors'
require_relative '../../logging'
require_relative 'error_context'
require_relative 'errors'

module AwsRubyDatabaseDriverWrapper
  module Plugins
    module Encryption
      # Opens the plugin's own connections to the kms_encryption metadata and key storage tables.
      #
      # The plugin must not read metadata over the application's connection: that connection can
      # be inside a transaction, can be mid-failover, and its session state belongs to the
      # application. Every metadata and key lookup therefore runs on a short lived connection of
      # its own, opened through the internal_connect pipeline so that it still picks up IAM
      # authentication and Secrets Manager credentials.
      class IndependentConnectionProvider
        include Logging

        # A connection is considered healthy above this success rate.
        HEALTHY_SUCCESS_RATE = 0.8
        # Or when its last failure is older than this.
        FAILURE_MEMORY_SEC = 300

        attr_reader :request_count, :successful_connection_count, :failed_connection_count,
                    :last_successful_connection_time, :last_failed_connection_time

        # @param service_container [Services::ServiceContainer]
        # @param audit_logger [AuditLogger, nil]
        def initialize(service_container, audit_logger: nil)
          raise ArgumentError, 'service_container is required' if service_container.nil?

          @service_container = service_container
          @audit_logger = audit_logger
          @lock = Mutex.new
          @request_count = 0
          @successful_connection_count = 0
          @failed_connection_count = 0
          @last_successful_connection_time = nil
          @last_failed_connection_time = nil
        end

        # Opens a connection, yields it, and closes it again.
        #
        # @param operation [String] the operation name used in audit records and error messages
        # @yieldparam connection [Object] a pg or mysql2 connection
        # @return [Object] whatever the block returns
        # @raise [Errors::IndependentConnectionError] if the connection cannot be opened
        def with_connection(operation: 'METADATA_QUERY')
          connection = open_connection(operation)
          begin
            yield connection
          ensure
            close_quietly(connection)
          end
        end

        # Opens a connection the caller is responsible for closing.
        #
        # @param operation [String] the operation name used in audit records and error messages
        # @return [Object] a pg or mysql2 connection
        # @raise [Errors::IndependentConnectionError] if the connection cannot be opened
        def open_connection(operation = 'METADATA_QUERY')
          host_info = @service_container.connection_service.current_host_info
          @lock.synchronize { @request_count += 1 }

          connection = @service_container.plugin_manager.internal_connect(
            host_info,
            @service_container.connection_service.driver_props.dup,
            @service_container.connection_service.wrapper_props,
            false
          )
          raise Errors::AwsError, 'The connect pipeline returned no connection' if connection.nil?

          record_success(host_info)
          connection
        rescue StandardError => e
          record_failure(host_info, operation, e)
          raise Errors::IndependentConnectionError.new(
            e.message,
            attempted_parameters: host_info&.url,
            connection_attempt: operation,
            failure_reason: e.class.name
          )
        end

        # Opens and immediately closes a connection.
        # @return [Boolean] true when a usable connection could be opened
        def validate_connection
          with_connection(operation: 'VALIDATE_CONNECTION') do |connection|
            !connection.nil? && !driver_dialect.closed?(connection)
          end
        rescue StandardError
          false
        end

        # @return [Float] the share of connection attempts that succeeded, 1.0 when none were made
        def connection_success_rate
          @lock.synchronize do
            total = @successful_connection_count + @failed_connection_count
            total.zero? ? 1.0 : @successful_connection_count.to_f / total
          end
        end

        # @return [Boolean] whether metadata connections are currently working
        def healthy?
          return true if connection_success_rate >= HEALTHY_SUCCESS_RATE

          last_failure = @lock.synchronize { @last_failed_connection_time }
          last_failure.nil? || (monotonic_now - last_failure) > FAILURE_MEMORY_SEC
        end

        # @return [String] a one line summary of the connection counters
        def health_status
          counters = @lock.synchronize do
            { requests: @request_count, successful: @successful_connection_count, failed: @failed_connection_count,
              last_success: @last_successful_connection_time, last_failure: @last_failed_connection_time }
          end

          status = format(
            'Independent connection status: healthy=%<healthy>s, requests=%<requests>d, ' \
            'successful=%<successful>d, failed=%<failed>d, success_rate=%<success_rate>.2f%%',
            healthy: healthy?, requests: counters[:requests], successful: counters[:successful],
            failed: counters[:failed], success_rate: connection_success_rate * 100
          )
          status += format(', last_success=%.1fs ago', monotonic_now - counters[:last_success]) if counters[:last_success]
          status += format(', last_failure=%.1fs ago', monotonic_now - counters[:last_failure]) if counters[:last_failure]
          status
        end

        # Logs {health_status} at info level while healthy and at warn level once it is not.
        # @return [void]
        def log_health_status
          status = health_status
          healthy = healthy?
          healthy ? logger.info(status) : logger.warn(status)

          successful, failed = @lock.synchronize { [@successful_connection_count, @failed_connection_count] }
          @audit_logger&.log_connection_health_check(
            connection_type: 'INDEPENDENT_CONNECTION',
            healthy: healthy,
            success_count: successful,
            failure_count: failed,
            success_rate: connection_success_rate
          )
        end

        private

        def driver_dialect
          @service_container.dialect_service.driver_dialect
        end

        def record_success(host_info)
          @lock.synchronize do
            @successful_connection_count += 1
            @last_successful_connection_time = monotonic_now
          end
          @audit_logger&.log_independent_connection_creation(target: host_info&.url, success: true)
        rescue StandardError => e
          # The connection is already open. A failure to write its audit record must not propagate to
          # open_connection's rescue, which would close the connection and report a successful connect
          # as a failure, so it is swallowed after being noted.
          logger.warn("Failed to write the independent connection audit record: #{e.message}")
        end

        def record_failure(host_info, operation, error)
          @lock.synchronize do
            @failed_connection_count += 1
            @last_failed_connection_time = monotonic_now
          end

          message = ErrorContext.builder
                                .operation(operation)
                                .build_message("Independent connection creation failed: #{error.message}")
          logger.debug(message)
          @audit_logger&.log_independent_connection_creation(
            target: host_info&.url, success: false, error_message: error.message
          )
        end

        def close_quietly(connection)
          return if connection.nil?

          driver_dialect.close_connection(connection)
        rescue StandardError
          nil
        end

        def monotonic_now
          Process.clock_gettime(Process::CLOCK_MONOTONIC)
        end
      end
    end
  end
end
