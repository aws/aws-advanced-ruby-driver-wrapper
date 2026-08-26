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
      # Uses the pg_query gem (libpg_query C extension) for accurate AST-based parsing.
      module PgStatementAnalyzer
        module_function

        def analyze(sql)
          begin
            require 'pg_query'
          rescue LoadError
            raise LoadError,
                  'pg_query gem is required for PostgreSQL SQL parsing. Add gem "pg_query" to your Gemfile.'
          end

          return QueryAnalysis.unknown unless sql.is_a?(String) && !sql&.strip&.empty?

          begin
            result = ::PgQuery.parse(sql)
            stmt = result.tree.stmts.first&.stmt
            return QueryAnalysis.unknown unless stmt

            stmt_hash = stmt.to_h
            extract_from_stmt(stmt_hash, parameterized?(stmt_hash))
          rescue ::PgQuery::ParseError
            fallback_analysis(sql)
          end
        end

        # Dispatches a parsed statement hash to the appropriate extract_* method.
        # @param stmt [Hash] top-level statement hash from pg_query
        # @param parameterized [Boolean]
        # @return [QueryAnalysis]
        def extract_from_stmt(stmt, parameterized)
          case stmt
          in { select_stmt: inner_stmt } then extract_select(inner_stmt, parameterized)
          in { insert_stmt: inner_stmt } then extract_insert(inner_stmt, parameterized)
          in { update_stmt: inner_stmt } then extract_update(inner_stmt, parameterized)
          in { delete_stmt: inner_stmt } then extract_delete(inner_stmt, parameterized)
          in { create_stmt: inner_stmt } then extract_create(inner_stmt)
          in { drop_stmt: inner_stmt }   then extract_drop(inner_stmt)
          else QueryAnalysis.unknown
          end
        end

        def extract_select(stmt, parameterized)
          tables = extract_tables_from_clause(Array(stmt[:from_clause]))
          where_cols = parameterized ? extract_where_columns(stmt[:where_clause]) : []
          for_update = Array(stmt[:locking_clause]).any?

          QueryAnalysis.new(
            query_type: QueryType::SELECT,
            tables: tables.freeze,
            write_columns: [].freeze,
            where_columns: where_cols.freeze,
            for_update: for_update,
            parameterized: parameterized
          )
        end

        def extract_insert(stmt, parameterized)
          table = stmt.dig(:relation, :relname)
          columns = Array(stmt[:cols]).map do |column_entry|
            ColumnInfo.new(table_name: table, column_name: column_entry[:res_target][:name])
          end

          QueryAnalysis.new(
            query_type: QueryType::INSERT,
            tables: table ? [table].freeze : [].freeze,
            write_columns: columns.freeze,
            where_columns: [].freeze,
            for_update: false,
            parameterized: parameterized
          )
        end

        def extract_update(stmt, parameterized)
          table = stmt.dig(:relation, :relname)
          set_cols = Array(stmt[:target_list]).filter_map do |target|
            res_target = target[:res_target]
            next unless res_target && param_ref?(res_target[:val])

            ColumnInfo.new(table_name: table, column_name: res_target[:name])
          end
          where_cols = parameterized ? extract_where_columns(stmt[:where_clause]) : []

          QueryAnalysis.new(
            query_type: QueryType::UPDATE,
            tables: table ? [table].freeze : [].freeze,
            write_columns: set_cols.freeze,
            where_columns: where_cols.freeze,
            for_update: false,
            parameterized: parameterized
          )
        end

        def extract_delete(stmt, parameterized)
          table = stmt.dig(:relation, :relname)
          where_cols = parameterized ? extract_where_columns(stmt[:where_clause]) : []

          QueryAnalysis.new(
            query_type: QueryType::DELETE,
            tables: table ? [table].freeze : [].freeze,
            write_columns: [].freeze,
            where_columns: where_cols.freeze,
            for_update: false,
            parameterized: parameterized
          )
        end

        def extract_create(stmt)
          table = stmt.dig(:relation, :relname)
          QueryAnalysis.new(
            query_type: QueryType::CREATE,
            tables: table ? [table].freeze : [].freeze,
            write_columns: [].freeze,
            where_columns: [].freeze,
            for_update: false,
            parameterized: false
          )
        end

        def extract_drop(stmt)
          tables = Array(stmt[:objects]).filter_map do |obj|
            obj.dig(:list, :items, -1, :string, :sval) ||
              obj.dig(:string, :sval)
          end
          QueryAnalysis.new(
            query_type: QueryType::DROP,
            tables: tables.freeze,
            write_columns: [].freeze,
            where_columns: [].freeze,
            for_update: false,
            parameterized: false
          )
        end

        def extract_tables_from_clause(from_clause)
          from_clause.flat_map do |from_entry|
            if from_entry[:range_var]
              [from_entry[:range_var][:relname]]
            elsif from_entry[:join_expr]
              extract_tables_from_join(from_entry[:join_expr])
            else
              []
            end
          end.compact.uniq
        end

        def extract_tables_from_join(join)
          [join[:larg], join[:rarg]].flat_map do |side|
            if side[:range_var]
              [side[:range_var][:relname]]
            elsif side[:join_expr]
              extract_tables_from_join(side[:join_expr])
            else
              []
            end
          end.compact
        end

        def extract_where_columns(where_clause)
          return [] unless where_clause

          cols = []
          extract_param_columns(where_clause, cols)
          cols
        end

        def extract_param_columns(expr, cols)
          return unless expr.is_a?(Hash)

          if expr[:a_expr]
            extract_param_columns_from_a_expr(expr[:a_expr], cols)
          elsif expr[:bool_expr]
            Array(expr[:bool_expr][:args]).each { |arg| extract_param_columns(arg, cols) }
          end
        end

        def extract_param_columns_from_a_expr(a_expr, cols)
          lexpr = a_expr[:lexpr]
          rexpr = a_expr[:rexpr]
          col_name = lexpr&.dig(:column_ref, :fields, -1, :string, :sval)
          return unless col_name

          case a_expr[:kind]
          when :AEXPR_IN, :AEXPR_BETWEEN, :AEXPR_BETWEEN_SYM
            # rexpr is a list — emit one entry per param_ref item
            Array(rexpr.dig(:list, :items)).each do |item|
              cols << ColumnInfo.new(table_name: nil, column_name: col_name) if param_ref?(item)
            end
          else
            # AEXPR_OP, AEXPR_OP_ANY, AEXPR_OP_ALL — rexpr is a single node
            cols << ColumnInfo.new(table_name: nil, column_name: col_name) if param_ref?(rexpr)
          end
        end

        def param_ref?(expr)
          return false unless expr.is_a?(Hash)

          expr.key?(:param_ref)
        end

        def parameterized?(hash)
          return true if hash.key?(:param_ref)

          hash.any? { |_, v| (v.is_a?(Hash) && parameterized?(v)) || (v.is_a?(Array) && v.any? { |e| e.is_a?(Hash) && parameterized?(e) }) }
        end

        # Keyword fallback when pg_query raises a parse error.
        # @param sql [String]
        # @return [QueryAnalysis]
        def fallback_analysis(sql)
          normalized_sql = sql.upcase.lstrip
          query_type = case normalized_sql
                       when /\ASELECT\b/ then QueryType::SELECT
                       when /\AINSERT\b/ then QueryType::INSERT
                       when /\AUPDATE\b/ then QueryType::UPDATE
                       when /\ADELETE\b/ then QueryType::DELETE
                       when /\ACREATE\b/ then QueryType::CREATE
                       when /\ADROP\b/   then QueryType::DROP
                       else QueryType::UNKNOWN
                       end
          QueryAnalysis.new(
            query_type: query_type,
            tables: [].freeze,
            write_columns: [].freeze,
            where_columns: [].freeze,
            for_update: false,
            parameterized: sql.match?(/\$\d+/) # fallback only; AST unavailable here
          )
        end
      end
    end
  end
end
