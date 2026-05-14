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
#
module AwsAdvancedRubyWrapper
  module DbDialects
    module BlueGreenDialect
      # Checks whether Blue/Green deployment status information is available via the given connection.
      #
      # @param connection [Object] the database connection to check.
      # @return [Boolean] true if Blue/Green status is available, false otherwise.
      # @raise [NotImplementedError]
      def blue_green_status_available?(connection)
        raise NotImplementedError
      end

      # Returns the SQL query used to retrieve the current Blue/Green deployment status.
      #
      # @return [String] the Blue/Green status query.
      # @raise [NotImplementedError]
      def blue_green_status_query
        raise NotImplementedError
      end
    end
  end
end
