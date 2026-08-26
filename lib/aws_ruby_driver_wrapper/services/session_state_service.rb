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

require_relative '../utils/sql_method_analyzer'

module AwsRubyDriverWrapper
  module Services
    class SessionStateService
      attr_accessor :in_transaction, :autocommit
      alias in_transaction? in_transaction
      alias autocommit? autocommit

      def initialize
        reset
      end

      def reset
        @in_transaction = false
        @autocommit = true
      end

      def update_transaction_state(method_name, args, autocommit_before)
        if Utils::SqlMethodAnalyzer.opens_transaction?(method_name, args, autocommit: autocommit?)
          self.in_transaction = true
        elsif Utils::SqlMethodAnalyzer.closes_transaction?(method_name, args) ||
              (!autocommit_before && Utils::SqlMethodAnalyzer.sets_autocommit?(method_name, args) &&
               Utils::SqlMethodAnalyzer.autocommit_value(args) == true)
          self.in_transaction = false
        end

        return unless Utils::SqlMethodAnalyzer.sets_autocommit?(method_name, args)

        val = Utils::SqlMethodAnalyzer.autocommit_value(args)
        self.autocommit = val unless val.nil?
      end

      # Begin tracking session state changes for a connection switch.
      def begin
        raise NotImplementedError
      end

      # Finalize session state tracking after a connection switch.
      def complete
        raise NotImplementedError
      end

      # Apply the current session state to the given connection.
      #
      # @param connection [Object]
      def apply_current_session_state(connection)
        raise NotImplementedError
      end

      # Apply the original session state to the given connection.
      #
      # @param connection [Object]
      def apply_original_session_state(connection)
        raise NotImplementedError
      end
    end
  end
end
