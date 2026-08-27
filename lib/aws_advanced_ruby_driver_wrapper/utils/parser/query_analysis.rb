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

require_relative 'query_type'

module AwsAdvancedRubyDriverWrapper
  module Utils
    module Parser
      # What one statement was found to be doing.
      #
      # +write_columns+ are the columns whose value comes from a bind parameter, which are the only
      # ones a caller can substitute a value for. +unbound_write_columns+ are columns the statement
      # also writes, but with something no caller can reach: a literal, an expression, a DEFAULT, or
      # a nested SELECT. +write_columns_complete+ says whether those two together name every column
      # the statement writes; false means the statement writes columns that could not be enumerated
      # at all, which is what an INSERT with no column list, an +INSERT ... SELECT+, and a statement
      # that would not parse all look like.
      QueryAnalysis = Data.define(:query_type, :tables, :write_columns, :where_columns, :for_update,
                                  :parameterized, :unbound_write_columns, :write_columns_complete) do
        def initialize(query_type:, tables:, write_columns:, where_columns:, for_update:, parameterized:,
                       unbound_write_columns: [].freeze, write_columns_complete: true)
          super
        end

        # A statement nothing could be established about. Its written columns are reported as not
        # enumerated, since a statement that could not be read may well be storing values.
        def self.unknown
          new(
            query_type: QueryType::UNKNOWN,
            tables: [].freeze,
            write_columns: [].freeze,
            where_columns: [].freeze,
            for_update: false,
            parameterized: false,
            write_columns_complete: false
          )
        end
      end

      # One column a statement touches. +parameter_index+ is the 1-based position of the bind
      # parameter that supplies its value, when the analyzer could work that out; nil means the
      # caller has to fall back to the order the columns were reported in.
      ColumnInfo = Data.define(:table_name, :column_name, :parameter_index) do
        def initialize(table_name:, column_name:, parameter_index: nil)
          super
        end
      end
    end
  end
end
