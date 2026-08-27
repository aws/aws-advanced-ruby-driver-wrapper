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
    module Parser
      module EncryptionAnnotationParser
        # Both placeholder styles are accepted, so that the same annotation works for mysql2's
        # positional +?+ and pg's numbered +$1+.
        ANNOTATION_PATTERN = %r{/\*@encrypt:([\w.]+)\*/\s*(?:\?|\$(\d+))}
        STRIP_PATTERN = %r{/\*@encrypt:[\w.]+\*/\s*}

        module_function

        # Returns a 1-based map of parameter index => "table.column" for each
        # /*@encrypt:table.column*/ ? or /*@encrypt:table.column*/ $n placeholder.
        # @param sql [String]
        # @return [Hash{Integer => String}]
        def parse_annotations(sql)
          return {} unless sql.is_a?(String) && !sql.empty?

          question_marks = sql.each_char.with_index.filter_map { |char, char_index| char_index if char == '?' }

          sql.to_enum(:scan, ANNOTATION_PATTERN)
             .each_with_object({}) do |_, result|
               match = Regexp.last_match
               next unless match

               # A numbered placeholder states its own position; a question mark is located by
               # counting the question marks that precede it.
               if match[2]
                 result[match[2].to_i] = match[1]
               else
                 param_index = question_marks.index(match.end(0) - 1)
                 result[param_index + 1] = match[1] if param_index
               end
             end
        end

        def strip_annotations(sql)
          return sql unless sql.is_a?(String) && !sql.empty?

          sql.gsub(STRIP_PATTERN, '')
        end

        def annotations?(sql)
          return false unless sql.is_a?(String) && !sql.empty?

          ANNOTATION_PATTERN.match?(sql)
        end
      end
    end
  end
end
