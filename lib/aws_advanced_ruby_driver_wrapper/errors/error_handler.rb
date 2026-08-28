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
