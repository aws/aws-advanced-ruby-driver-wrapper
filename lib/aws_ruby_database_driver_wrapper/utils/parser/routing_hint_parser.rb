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

require_relative 'routing_hint'

module AwsRubyDatabaseDriverWrapper
  module Utils
    module Parser
      module RoutingHintParser
        HINT_PATTERN = %r{/\*\s*@\s*(reader|writer|keep)\s*\*/}i

        HINT_MAP = {
          'reader' => RoutingHint::READER,
          'writer' => RoutingHint::WRITER,
          'keep' => RoutingHint::KEEP
        }.freeze

        module_function

        def parse_routing_hint(sql)
          return nil unless sql.is_a?(String) && !sql.empty?

          hint_match = HINT_PATTERN.match(sql)
          return nil unless hint_match

          HINT_MAP[hint_match[1].downcase]
        end

        def strip_routing_hint(sql)
          return sql unless sql.is_a?(String) && !sql.empty?

          sql.gsub(HINT_PATTERN, '').strip
        end
      end
    end
  end
end
