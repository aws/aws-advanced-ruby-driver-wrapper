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
  module Monitoring
    # Thread-safe connection wrapper with compare-and-set semantics.
    # Automatically closes the old connection when replaced.
    class MonitorConnection
      def initialize
        @connection = Concurrent::AtomicReference.new(nil)
      end

      # Returns the current connection, or nil.
      def get
        @connection.value
      end

      # Replaces the current connection. Closes the old one unless close_old is false.
      # @param new_conn [Object, nil] the new connection.
      # @param close_old [Boolean] whether to close the previous connection.
      def set(new_conn, close_old: true)
        old = @connection.get_and_set(new_conn)
        safe_close(old) if close_old && old && !old.equal?(new_conn)
      end

      # Atomically sets the connection only if the current value is `expected` (identity check).
      # @param expected [Object, nil] the expected current connection.
      # @param new_conn [Object] the new connection to set.
      # @return [Boolean] true if the swap succeeded.
      def compare_and_set(expected, new_conn)
        @connection.compare_and_set(expected, new_conn)
      end

      # Closes and nils the connection.
      def close
        set(nil)
      end

      private

      def safe_close(conn)
        conn.close
      rescue StandardError
        nil
      end
    end
  end
end
