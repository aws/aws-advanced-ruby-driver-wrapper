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

module AwsRubyDatabaseDriverWrapper
  module Utils
    module Parser
      class SqlParser
        SqlAnalysisResult = Data.define(:query_type, :affected_tables)

        def initialize(driver_dialect)
          @analyzer = resolve_analyzer(driver_dialect)
        end

        def analyze_sql(sql)
          return empty_result unless sql.is_a?(String) && !sql.strip.empty?

          analysis = @analyzer.analyze(sql)
          tables = analysis.tables.to_set { |table_name| strip_schema_prefix(table_name) }
          SqlAnalysisResult.new(query_type: analysis.query_type, affected_tables: tables)
        end

        # Maps 1-based parameter indices to column names.
        # SELECT => WHERE clause columns only. INSERT/UPDATE => SET/column-list columns only.
        # @param sql [String, nil]
        # @return [Hash{Integer => String}]
        def column_parameter_mapping(sql)
          return {} unless sql.is_a?(String) && !sql&.strip&.empty?

          analysis = @analyzer.analyze(sql)

          case analysis.query_type
          when QueryType::SELECT
            analysis.where_columns.each_with_index.to_h { |column_info, idx| [idx + 1, column_info.column_name] }
          when QueryType::INSERT, QueryType::UPDATE
            analysis.write_columns.each_with_index.to_h { |column_info, idx| [idx + 1, column_info.column_name] }
          else
            {}
          end
        rescue StandardError
          {}
        end

        private

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
