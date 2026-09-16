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
    module Gdb
      # The host roles and regions that the GDB failover plugin may target during failover.
      module GdbFailoverMode
        STRICT_WRITER = :strict_writer
        STRICT_HOME_READER = :strict_home_reader
        STRICT_OUT_OF_HOME_READER = :strict_out_of_home_reader
        STRICT_ANY_READER = :strict_any_reader
        HOME_READER_OR_WRITER = :home_reader_or_writer
        OUT_OF_HOME_READER_OR_WRITER = :out_of_home_reader_or_writer
        ANY_READER_OR_WRITER = :any_reader_or_writer

        ALL = [
          STRICT_WRITER,
          STRICT_HOME_READER,
          STRICT_OUT_OF_HOME_READER,
          STRICT_ANY_READER,
          HOME_READER_OR_WRITER,
          OUT_OF_HOME_READER_OR_WRITER,
          ANY_READER_OR_WRITER
        ].freeze

        # Maps every accepted spelling of a mode to the mode itself. Kebab-case, snake_case and
        # squashed spellings are all accepted, e.g. 'strict-home-reader', 'strict_home_reader'
        # and 'stricthomereader'.
        NAME_TO_VALUE = ALL.each_with_object({}) do |mode, mapping|
          snake = mode.to_s
          mapping[snake] = mode
          mapping[snake.tr('_', '-')] = mode
          mapping[snake.delete('_')] = mode
        end.freeze

        # Resolves a configured mode string into one of the mode constants.
        #
        # @param value [String, Symbol, nil] the configured value
        # @return [Symbol, nil] the mode, or nil when no value was configured
        # @raise [ArgumentError] if the value does not name a known mode
        def self.from_value(value)
          return nil if value.nil?

          normalized = value.to_s.strip.downcase
          return nil if normalized.empty?

          NAME_TO_VALUE.fetch(normalized) do
            raise ArgumentError, "Invalid global database failover mode: '#{value}'"
          end
        end
      end
    end
  end
end
