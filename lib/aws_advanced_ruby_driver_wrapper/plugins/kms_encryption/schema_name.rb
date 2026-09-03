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
    module Encryption
      # A validated database schema name.
      #
      # Schema names cannot be bound as statement parameters, so the plugin has to
      # interpolate them into the metadata queries. Wrapping the name in this type keeps
      # that interpolation safe: only plain identifiers are accepted, which rules out
      # quoting, whitespace, comments, and statement separators.
      class SchemaName
        VALID_PATTERN = /\A[a-zA-Z_][a-zA-Z0-9_]*\z/

        attr_reader :value

        # @param name [String, Symbol, SchemaName] the schema name to validate
        # @return [SchemaName]
        # @raise [ArgumentError] if the name is empty or is not a plain SQL identifier
        def self.of(name)
          name.is_a?(SchemaName) ? name : new(name)
        end

        # @param value [String, Symbol]
        # @raise [ArgumentError] if the name is empty or is not a plain SQL identifier
        def initialize(value)
          name = value.to_s
          raise ArgumentError, 'Schema name cannot be empty' if value.nil? || name.strip.empty?

          unless VALID_PATTERN.match?(name)
            raise ArgumentError,
                  "Invalid schema name: #{name.inspect}. Schema names must start with a letter or underscore and " \
                  'contain only letters, digits, and underscores.'
          end

          @value = name.freeze
          freeze
        end

        def to_s
          @value
        end
        alias to_str to_s

        def ==(other)
          other.is_a?(SchemaName) && other.value == @value
        end
        alias eql? ==

        def hash
          [self.class, @value].hash
        end
      end
    end
  end
end
