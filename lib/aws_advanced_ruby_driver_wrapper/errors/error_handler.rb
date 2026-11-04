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
      TEMPORARY_RESOLUTION_FAILURE = 'temporary failure'

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

      # Whether the error, or any error in its cause chain, is a driver error meaning the host name does not
      # exist. Temporary resolver failures ("Temporary failure in name resolution") don't count, since the
      # same host may resolve on the next attempt.
      #
      # @param error [Exception]
      # @return [Boolean]
      def unknown_host_error?(error)
        check_cause_chain(error) { |_, current| unknown_host?(current) && !temporary_resolution_failure?(current) }
      end

      private

      # Driver-specific check for an error raised when the host name could not be resolved.
      def unknown_host?(_error)
        false
      end

      def temporary_resolution_failure?(error)
        [error, error.cause].compact.any? { |e| e.message.to_s.downcase.include?(TEMPORARY_RESOLUTION_FAILURE) }
      end

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
