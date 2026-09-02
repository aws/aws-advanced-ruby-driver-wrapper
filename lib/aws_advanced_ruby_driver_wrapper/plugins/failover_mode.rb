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
  module Plugins
    module FailoverMode
      STRICT_WRITER = :strict_writer
      STRICT_READER = :strict_reader
      READER_OR_WRITER = :reader_or_writer

      def self.from_value(value)
        return nil if value.nil? || value.to_s.empty?

        case value.to_s.downcase
        when 'strict_writer', 'strict-writer', 'strictwriter'
          STRICT_WRITER
        when 'strict_reader', 'strict-reader', 'strictreader'
          STRICT_READER
        when 'reader_or_writer', 'reader-or-writer', 'readerorwriter'
          READER_OR_WRITER
        else
          raise ArgumentError, "Invalid failover mode: '#{value}'"
        end
      end
    end
  end
end
