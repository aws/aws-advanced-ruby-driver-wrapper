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
    # Trilogy errors carry no SQLSTATE, so they are classified by class and by the server's error code.
    class TrilogyErrorHandler
      include ErrorHandler

      LOGIN_ERROR_CODES = Set[
        1044, # ER_DBACCESS_DENIED_ERROR
        1045  # ER_ACCESS_DENIED_ERROR
      ].freeze
      READ_ONLY_ERROR_CODES = Set[1290, 1836].freeze
      LOCK_WAIT_TIMEOUT_ERROR_CODE = 1205

      # A protocol violation raised while receiving the authentication response. Unlike a clean
      # ER_ACCESS_DENIED_ERROR (1045), trilogy raises this from its C extension as a codeless
      # Trilogy::QueryError (error_code nil, not a ConnectionError), so it is matched by its message
      # marker rather than by code. The server aborting the auth handshake this way means the
      # credential was not accepted, so for login-retry purposes it is a login error.
      AUTH_PROTOCOL_VIOLATION = 'trilogy_auth_recv'
      PROTOCOL_VIOLATION_MARKER = 'TRILOGY_PROTOCOL_VIOLATION'

      def initialize(driver_dialect)
        @driver_dialect = driver_dialect
      end

      # Every Trilogy::ConnectionError except those that do not mean the server is unreachable: rejected
      # credentials, a lock wait timeout, an authentication plugin trilogy refuses (an IAM token without
      # enable_cleartext_plugin) and a connection the application closed. Read and write timeouts count,
      # as they do for mysql2.
      def network_error?(error)
        check_cause_chain(error) { |_, current| network_failure?(current) }
      end

      def network_error_by_sql_state?(_sql_state)
        false
      end

      def login_error?(error)
        check_cause_chain(error) do |_, current|
          LOGIN_ERROR_CODES.include?(error_code(current)) || auth_protocol_violation?(current)
        end
      end

      def login_error_by_sql_state?(_sql_state)
        false
      end

      def read_only_error?(error)
        check_cause_chain(error) { |_, current| READ_ONLY_ERROR_CODES.include?(error_code(current)) }
      end

      def read_only_error_by_sql_state?(_sql_state, error_code = nil)
        READ_ONLY_ERROR_CODES.include?(error_code)
      end

      private

      def network_failure?(error)
        return false unless defined?(::Trilogy::ConnectionError) && error.is_a?(::Trilogy::ConnectionError)
        return false if error.is_a?(::Trilogy::ConnectionClosed) || error.is_a?(::Trilogy::AuthPluginError)

        code = error_code(error)
        !LOGIN_ERROR_CODES.include?(code) && code != LOCK_WAIT_TIMEOUT_ERROR_CODE
      end

      def error_code(error)
        error.respond_to?(:error_code) ? error.error_code : nil
      end

      # True for a codeless protocol violation raised during the auth handshake. trilogy surfaces a
      # rejected/aborted credential exchange as a Trilogy::QueryError carrying "TRILOGY_PROTOCOL_VIOLATION
      # (trilogy_auth_recv)" with no MySQL error code, so it is identified by message rather than code.
      # Scoped to the auth phase so a mid-session protocol error is not misread as a login failure.
      def auth_protocol_violation?(error)
        return false unless defined?(::Trilogy::Error) && error.is_a?(::Trilogy::Error)
        return false unless error_code(error).nil?

        message = error.message.to_s
        message.include?(PROTOCOL_VIOLATION_MARKER) && message.include?(AUTH_PROTOCOL_VIOLATION)
      end
    end
  end
end
