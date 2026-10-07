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

# Stand-in for Action Cable's PostgreSQL subscription adapter, which is not a dependency of this gem.
# It keeps the check every supported Action Cable version (7.2 to 8.1) runs on the connection it is given.
module ActionCable
  module SubscriptionAdapter
    class PostgreSQL
      def check(pg_conn)
        verify!(pg_conn)
      end

      private

      def verify!(pg_conn)
        return if pg_conn.is_a?(PG::Connection)

        raise 'The Active Record database must be PostgreSQL in order to use the PostgreSQL Action Cable storage adapter'
      end
    end
  end
end
