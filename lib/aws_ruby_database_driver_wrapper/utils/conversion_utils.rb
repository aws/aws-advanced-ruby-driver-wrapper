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
  module Utils
    # Utility methods for converting values from database query results into Ruby types.
    module ConversionUtils
      require 'time'
      def to_boolean(value)
        case value
        when true, 1, '1', 'true', 't', 'TRUE', 'T'
          true
        else
          false
        end
      end

      def to_float(value)
        Float(value || 0)
      rescue ArgumentError, TypeError
        0.0
      end

      def to_time(value)
        case value
        when Time
          value
        when String
          Time.parse(value)
        else
          Time.now
        end
      rescue ArgumentError
        Time.now
      end
    end
  end
end
