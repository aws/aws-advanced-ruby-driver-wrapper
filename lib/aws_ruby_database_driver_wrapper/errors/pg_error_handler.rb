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

require_relative 'error_handler'

module AwsRubyDatabaseDriverWrapper
  module Errors
    class PgErrorHandler
      include ErrorHandler

      NETWORK_SQL_STATE_PREFIXES = %w[57P01 57P02 57P03 58 08 99 F0].freeze
      ACCESS_ERROR_SQL_STATES = Set['08004', '28P01', '28000'].freeze
      READ_ONLY_SQL_STATE = '25006'
      LOGIN_ERROR_MESSAGE = 'authentication failed'
      NETWORK_ERROR_MESSAGES = [
        'unexpected eof',
        'closed the connection unexpectedly',
        'reset by peer',
        'could not receive data',
        'could not send data',
        'connection not open',
        'no connection to the server',
        'connection is closed',
        'broken pipe',
        'terminating connection due to administrator command',
        "can't get socket descriptor",
        'ssl connection has been closed unexpectedly'
      ].freeze

      # Failures raised while establishing a connection, where the server was never reached and so
      # never had the chance to accept or reject the login. These are transient and worth retrying.
      # libpq discards the structured error fields for connect-time failures, so the message text
      # is the only signal available.
      CONNECT_FAILURE_MESSAGES = [
        'connection refused',
        'timeout expired',
        'could not translate host name',
        'no route to host',
        'network is unreachable',
        'host is unreachable',
        'could not connect to server',
        'no such file or directory', # unix socket path does not exist
        'connection timed out'
      ].freeze

      # Rejections issued by a server that was successfully reached. Retrying to connect is futile because
      # the cause is the credentials, the requested database, or server configuration rather than the network path.
      SERVER_REJECTION_MESSAGES = [
        LOGIN_ERROR_MESSAGE,
        'pg_hba.conf',
        'does not exist',
        'is not permitted',
        'too many clients'
      ].freeze

      def initialize(driver_dialect)
        @driver_dialect = driver_dialect
      end

      def network_error?(error)
        return true if super

        check_cause_chain(error) { |_, current| connection_bad_network_error?(current) }
      end

      def network_error_by_sql_state?(sql_state)
        return false if sql_state.nil?

        NETWORK_SQL_STATE_PREFIXES.any? { |prefix| sql_state.start_with?(prefix) }
      end

      def login_error?(error)
        return true if super

        # PG::ConnectionBad from auth failure during connect may not carry a SQLSTATE.
        # Fall back to message inspection.
        if defined?(PG::ConnectionBad) && error.is_a?(PG::ConnectionBad)
          msg = error.message
          return msg.include?(LOGIN_ERROR_MESSAGE) if msg
        end

        false
      end

      def login_error_by_sql_state?(sql_state)
        return false if sql_state.nil?

        ACCESS_ERROR_SQL_STATES.include?(sql_state)
      end

      def read_only_error_by_sql_state?(sql_state, _error_code = nil)
        sql_state == READ_ONLY_SQL_STATE
      end

      private

      def connection_bad_network_error?(error)
        return false unless defined?(PG::ConnectionBad) && error.is_a?(PG::ConnectionBad)

        msg = error.message&.downcase
        return false if msg.nil?
        return false if server_rejection?(msg)

        NETWORK_ERROR_MESSAGES.any? { |pattern| msg.include?(pattern) } ||
          CONNECT_FAILURE_MESSAGES.any? { |pattern| msg.include?(pattern) }
      end

      def server_rejection?(msg)
        SERVER_REJECTION_MESSAGES.any? { |pattern| msg.include?(pattern) }
      end
    end
  end
end
