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
    class MysqlErrorHandler
      include ErrorHandler

      ACCESS_ERROR_SQL_STATE = '28000'
      READ_ONLY_ERROR_CODES = Set[1290, 1836].freeze

      def initialize(driver_dialect)
        @driver_dialect = driver_dialect
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
    end
  end
end
