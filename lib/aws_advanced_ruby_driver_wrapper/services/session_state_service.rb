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

module AwsAdvancedRubyDriverWrapper
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

      def update_transaction_state(method_name, args, autocommit_before, dialect, connection, succeeded: true)
        connection_in_transaction = dialect.reported_in_transaction(connection)
        unless connection_in_transaction.nil?
          self.in_transaction = connection_in_transaction
          return
        end
        # When the statement failed, SQL inference can't tell what took effect, so keep the current state.
        return unless succeeded

        effect = Utils::SqlMethodAnalyzer.transaction_effect(
          method_name, args, autocommit: autocommit?, autocommit_before: autocommit_before
        )
        if effect.opens_transaction
          self.in_transaction = true
        elsif effect.closes_transaction
          self.in_transaction = false
        end
        self.autocommit = effect.autocommit_value unless effect.autocommit_value.nil?
      end
    end
  end
end
