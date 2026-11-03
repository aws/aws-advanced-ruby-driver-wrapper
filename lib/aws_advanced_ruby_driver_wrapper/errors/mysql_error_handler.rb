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

module AwsAdvancedRubyDriverWrapper
  module Errors
    class MysqlErrorHandler
      include ErrorHandler

      ACCESS_ERROR_SQL_STATE = '28000'
      READ_ONLY_ERROR_CODES = Set[1290, 1836].freeze
      NETWORK_ERROR_CODES = Set[
        2002, # CR_CONNECTION_ERROR (can't connect via socket)
        2003, # CR_CONN_HOST_ERROR (can't connect to host)
        2006, # CR_SERVER_GONE_ERROR (server has gone away)
        2013, # CR_SERVER_LOST (lost connection during query)
        2026, # CR_SSL_CONNECTION_ERROR
        2055, # CR_SERVER_LOST_EXTENDED (lost connection with state info)
        4031  # ER_CLIENT_INTERACTION_TIMEOUT (MySQL 8.0.24+ closed a connection that exceeded wait_timeout)
      ].freeze

      def initialize(driver_dialect)
        @driver_dialect = driver_dialect
      end

      def network_error?(error)
        return true if super

        check_cause_chain(error) { |_, current| connection_error_network?(current) }
      end

      def network_error_by_sql_state?(sql_state)
        return false if sql_state.nil?

        sql_state.start_with?('08') && sql_state != '08004'
      end

      def login_error_by_sql_state?(sql_state)
        return false if sql_state.nil?

        sql_state == ACCESS_ERROR_SQL_STATE
      end

      def read_only_error?(error)
        check_cause_chain(error) do |sql_state, ex|
          error_code = ex.respond_to?(:error_number) ? ex.error_number : nil
          read_only_error_by_sql_state?(sql_state, error_code)
        end
      end

      def read_only_error_by_sql_state?(sql_state, error_code = nil)
        sql_state == 'HY000' && !error_code.nil? && READ_ONLY_ERROR_CODES.include?(error_code)
      end

      private

      def connection_error_network?(error)
        return false unless defined?(Mysql2::Error) && error.is_a?(Mysql2::Error)

        NETWORK_ERROR_CODES.include?(error.error_number) || read_timeout?(error)
      end

      # mysql2 raises Mysql2::Error::TimeoutError for two unrelated conditions. A client-side read_timeout
      # carries no error number, and mysql2 invalidates the socket before raising it, so the connection is
      # unusable. A lock wait timeout (1205) is a server error on a healthy connection and is excluded.
      def read_timeout?(error)
        error.is_a?(Mysql2::Error::TimeoutError) && error.error_number.nil?
      end
    end
  end
end
