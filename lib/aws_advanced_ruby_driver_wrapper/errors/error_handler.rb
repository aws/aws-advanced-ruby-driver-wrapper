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

module AwsAdvancedRubyDriverWrapper
  module Errors
    module ErrorHandler
      def network_error?(error)
        check_cause_chain(error) { |sql_state, _| network_error_by_sql_state?(sql_state) }
      end

      def network_error_by_sql_state?(sql_state)
        raise NotImplementedError
      end

      def login_error?(error)
        check_cause_chain(error) { |sql_state, _| login_error_by_sql_state?(sql_state) }
      end

      def login_error_by_sql_state?(sql_state)
        raise NotImplementedError
      end

      def read_only_error?(error)
        check_cause_chain(error) { |sql_state, _| read_only_error_by_sql_state?(sql_state) }
      end

      def read_only_error_by_sql_state?(sql_state, error_code = nil)
        raise NotImplementedError
      end

      # Whether +error+ is a server-side error (the server received the request and answered with an
      # error), as opposed to a client/transport failure. Used by the Blue/Green status monitor to
      # decide whether to settle the status at NOT_CREATED or tear the monitoring connection down.
      # The default reads the normalized SQLSTATE, which mysql2 and pg report natively; a driver whose
      # errors carry no SQLSTATE (trilogy) overrides this to classify by its numeric error code.
      def server_error?(error)
        !@driver_dialect.sql_state(error).nil?
      end

      # Whether +error+ is a schema/syntax error (SQLSTATE class '42': missing table, unknown column,
      # parse error, missing routine). The Blue/Green status monitor reads this as "the status
      # table/function is not there", i.e. NOT_CREATED. Default is SQLSTATE-based; trilogy overrides.
      def schema_error?(error)
        @driver_dialect.sql_state(error)&.start_with?('42') || false
      end

      private

      def extract_sql_state(error)
        @driver_dialect.sql_state(error)
      end

      def check_cause_chain(error)
        current = error
        while current
          sql_state = extract_sql_state(current)
          return true if yield(sql_state, current)

          current = current.cause
        end
        false
      end
    end
  end
end
