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
        check_cause_chain(error) { |_, current| LOGIN_ERROR_CODES.include?(error_code(current)) }
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
    end
  end
end
