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

module AwsRubyDatabaseDriverWrapper
  module Services
    class SessionStateService
      # @return [Boolean]
      def in_transaction?
        raise NotImplementedError
      end

      # @param value [Boolean]
      def in_transaction=(value)
        raise NotImplementedError
      end

      def autocommit?
        raise NotImplementedError
      end

      def autocommit=(value)
        raise NotImplementedError
      end

      # Reset all tracked session state.
      def reset
        raise NotImplementedError
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
