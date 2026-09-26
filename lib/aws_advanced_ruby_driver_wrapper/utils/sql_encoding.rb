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
  module Utils
    module SqlEncoding
      module_function

      # A copy of the SQL as valid UTF-8, which is what the patterns and parsers that inspect statements
      # can read. A statement in an encoding that is not ASCII-compatible, such as UTF-16, cannot be
      # matched against a UTF-8 pattern at all, and neither can one with bytes that are invalid in its
      # encoding.
      #
      # Only the copy is converted. The SQL a driver is sent is the caller's own, since the driver
      # converts it to the connection's encoding itself.
      #
      # A character with no UTF-8 equivalent, or a byte that is invalid, is replaced rather than raised on,
      # so that inspecting a statement never fails a call the driver would have made. The same goes for
      # the few encodings Ruby has no converter to UTF-8 for, whose statements go uninspected.
      #
      # @param sql [Object] the SQL to inspect
      # @return [String, Object, nil] the SQL as valid UTF-8, anything that is not a String as it is,
      #   or nil for SQL that cannot be converted
      def inspectable(sql)
        return sql unless sql.is_a?(String)
        return sql.valid_encoding? ? sql : sql.scrub if sql.encoding == Encoding::UTF_8
        return sql if sql.ascii_only? && sql.encoding.ascii_compatible?

        sql.encode(Encoding::UTF_8, invalid: :replace, undef: :replace)
      rescue Encoding::ConverterNotFoundError
        nil
      end
    end
  end
end
