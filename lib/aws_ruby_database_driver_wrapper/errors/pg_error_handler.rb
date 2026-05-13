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

require 'set'
require_relative 'error_handler'

module AwsRubyDatabaseDriverWrapper
  module Errors
    class PgErrorHandler
      include ErrorHandler

      NETWORK_SQL_STATE_PREFIXES = %w[57P01 57P02 57P03 58 08 99 F0].freeze
      ACCESS_ERROR_SQL_STATES = Set['08004', '28P01', '28000'].freeze
      READ_ONLY_SQL_STATE = '25006'

      def initialize(driver_dialect)
        @driver_dialect = driver_dialect
      end

      def network_error_by_sql_state?(sql_state)
        return false if sql_state.nil?

        NETWORK_SQL_STATE_PREFIXES.any? { |prefix| sql_state.start_with?(prefix) }
      end

      def login_error_by_sql_state?(sql_state)
        return false if sql_state.nil?

        ACCESS_ERROR_SQL_STATES.include?(sql_state)
      end

      def read_only_error_by_sql_state?(sql_state, _error_code = nil)
        sql_state == READ_ONLY_SQL_STATE
      end
    end
  end
end
