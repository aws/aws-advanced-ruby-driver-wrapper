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

require_relative 'query_analysis'
require_relative 'query_type'

module AwsAdvancedRubyDriverWrapper
  module Utils
    module Parser
      class SqlParser
        # What a statement was found to be doing: the kind of statement, the tables it touches with
        # any schema prefix removed, which bind parameter fills which column, and what it writes that
        # no bind parameter fills. The last two are what a caller needs to distinguish between a
        # column it can put a value into from one it cannot.
        SqlAnalysisResult = Data.define(:query_type, :affected_tables, :parameter_column_names,
                                        :unbound_write_columns, :write_columns_complete) do
          def initialize(query_type:, affected_tables:, parameter_column_names: {}.freeze,
                         unbound_write_columns: [].freeze, write_columns_complete: true)
            super
          end
        end

        def initialize(driver_dialect)
          @analyzer = resolve_analyzer(driver_dialect)
        end

        # @raise [StandardError] whatever the underlying analyzer raises on SQL it cannot read
        def analyze_sql(sql)
          return empty_result unless sql.is_a?(String) && !sql.strip.empty?

          analysis = @analyzer.analyze(sql)
          SqlAnalysisResult.new(
            query_type: analysis.query_type,
            affected_tables: analysis.tables.to_set { |table_name| strip_schema_prefix(table_name) },
            parameter_column_names: mapping_of(analysis),
            unbound_write_columns: analysis.unbound_write_columns,
            write_columns_complete: analysis.write_columns_complete
          )
        end

        # Maps 1-based parameter indices to column names.
        # SELECT => WHERE clause columns only. INSERT/UPDATE => SET/column-list columns only.
        #
        # A statement the analyzer could not read is reported as an empty mapping, not as a failure:
        # the callers that must not write a value they cannot place look at the analysis itself.
        #
        # @param sql [String, nil]
        # @return [Hash{Integer => String}]
        def column_parameter_mapping(sql)
          analyze_sql(sql).parameter_column_names
        rescue StandardError
          {}
        end

        private

        def mapping_of(analysis)
          case analysis.query_type
          when QueryType::SELECT then parameter_mapping(analysis.where_columns)
          when QueryType::INSERT, QueryType::UPDATE then parameter_mapping(analysis.write_columns)
          else {}
          end
        end

        # Bind parameters are numbered from 1. An analyzer that could work out which parameter fills
        # which column says so on the ColumnInfo; one that could not leaves it nil, and the columns
        # are then taken in the order they were reported.
        def parameter_mapping(column_infos)
          column_infos.each_with_index.to_h do |column_info, position|
            [column_info.parameter_index || (position + 1), column_info.column_name]
          end
        end

        def resolve_analyzer(driver_dialect)
          if pg_dialect?(driver_dialect)
            require_relative 'pg_statement_analyzer'
            PgStatementAnalyzer
          else
            require_relative 'mysql_statement_analyzer'
            MysqlStatementAnalyzer
          end
        end

        def pg_dialect?(driver_dialect)
          driver_dialect.is_a?(DriverDialects::PgDriverDialect)
        end

        def empty_result
          SqlAnalysisResult.new(query_type: QueryType::UNKNOWN, affected_tables: Set.new)
        end

        def strip_schema_prefix(table)
          table.split('.').last
        end
      end
    end
  end
end
