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
            statements = result.tree.stmts
            stmt = statements.first&.stmt
            return QueryAnalysis.unknown unless stmt

            stmt_hash = stmt.to_h
            analysis = extract_from_stmt(stmt_hash, parameterized?(stmt_hash))
            statements.length > 1 ? with_trailing_statements(analysis, statements) : analysis
          rescue ::PgQuery::ParseError
            fallback_analysis(sql)
          end
        end

        # Only the first statement of a multi-statement string is analyzed, so what the rest of them
        # write is unknown. Their tables are still collected, since a caller that has to decide
        # whether the string touches an encrypted column needs to know about them.
        # @return [QueryAnalysis]
        def with_trailing_statements(analysis, statements)
          tables = statements.flat_map { |wrapped| statement_tables(wrapped.stmt.to_h) }
          analysis.with(
            tables: (analysis.tables | tables).freeze,
            write_columns_complete: false
          )
        end

        # A SELECT names its tables in a FROM clause; the statements that write name the one they
        # write in a relation of their own.
        def statement_tables(stmt)
          return extract_tables_from_clause(Array(stmt.dig(:select_stmt, :from_clause))) if stmt.key?(:select_stmt)

          written = stmt.values_at(:insert_stmt, :update_stmt, :delete_stmt).compact.first
          written ? [written.dig(:relation, :relname)].compact : []
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
          declared = Array(stmt[:cols]).filter_map { |column_entry| column_entry.dig(:res_target, :name) }
          value_rows = Array(stmt.dig(:select_stmt, :select_stmt, :values_lists))
          bound, unbound, complete = extract_values(table, declared, value_rows)
          upsert_bound, upsert_unbound = extract_assignments(table, Array(stmt.dig(:on_conflict_clause, :target_list)))

          QueryAnalysis.new(
            query_type: QueryType::INSERT,
            tables: table ? [table].freeze : [].freeze,
            write_columns: (bound + upsert_bound).freeze,
            where_columns: [].freeze,
            for_update: false,
            parameterized: parameterized,
            unbound_write_columns: (unbound + upsert_unbound).freeze,
            write_columns_complete: complete
          )
        end

        def extract_update(stmt, parameterized)
          table = stmt.dig(:relation, :relname)
          set_cols, unbound = extract_assignments(table, Array(stmt[:target_list]))
          where_cols = parameterized ? extract_where_columns(stmt[:where_clause]) : []

          QueryAnalysis.new(
            query_type: QueryType::UPDATE,
            tables: table ? [table].freeze : [].freeze,
            write_columns: set_cols.freeze,
            where_columns: where_cols.freeze,
            for_update: false,
            parameterized: parameterized,
            unbound_write_columns: unbound.freeze
          )
        end

        # Pairs each declared column of an INSERT with the value expression that fills it, for every
        # row of the VALUES list, and reports which parameter supplies it.
        #
        # An INSERT can only be read column by column when it does both of those things. Without a
        # column list the values are positional over the table's own column order, which the
        # statement does not carry; with a nested SELECT the values never pass through the client at
        # all. Either way the columns it writes cannot be enumerated.
        #
        # @return [Array(Array<ColumnInfo>, Array<ColumnInfo>, Boolean)] the columns filled by a bind
        #   parameter, those filled by something else, and whether every written column was found
        def extract_values(table, declared, value_rows)
          return [[], [], false] if declared.empty? || value_rows.empty?

          bound = []
          unbound = []
          complete = true

          value_rows.each do |row|
            values = Array(row.dig(:list, :items))
            complete = false unless values.length == declared.length

            declared.each_with_index do |column_name, position|
              value = values[position]
              if param_ref?(value)
                bound << ColumnInfo.new(table_name: table, column_name: column_name, parameter_index: param_number(value))
              elsif !null_const?(value)
                unbound << ColumnInfo.new(table_name: table, column_name: column_name)
              end
            end
          end

          [bound, unbound, complete]
        end

        # The assignments of an UPDATE's SET clause, or of an +ON CONFLICT DO UPDATE SET+ clause,
        # which have the same shape.
        #
        # @return [Array(Array<ColumnInfo>, Array<ColumnInfo>)] the columns assigned from a bind
        #   parameter, and those assigned from something else
        def extract_assignments(table, target_list)
          bound = []
          unbound = []

          target_list.each do |target|
            res_target = target[:res_target]
            column_name = res_target && res_target[:name]
            next unless column_name

            value = res_target[:val]
            if param_ref?(value)
              bound << ColumnInfo.new(table_name: table, column_name: column_name, parameter_index: param_number(value))
            elsif !null_const?(value)
              unbound << ColumnInfo.new(table_name: table, column_name: column_name)
            end
          end

          [bound, unbound]
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
              cols << ColumnInfo.new(table_name: nil, column_name: col_name, parameter_index: param_number(item)) if param_ref?(item)
            end
          else
            # AEXPR_OP, AEXPR_OP_ANY, AEXPR_OP_ALL — rexpr is a single node
            cols << ColumnInfo.new(table_name: nil, column_name: col_name, parameter_index: param_number(rexpr)) if param_ref?(rexpr)
          end
        end

        def param_ref?(expr)
          return false unless expr.is_a?(Hash)

          expr.key?(:param_ref)
        end

        # @return [Integer, nil] which parameter the expression is, 1-based, as written in the SQL
        def param_number(expr)
          expr.dig(:param_ref, :number) if expr.is_a?(Hash)
        end

        # A NULL is the one value that needs no encrypting, so a column filled with one is not a
        # column written in the clear.
        def null_const?(expr)
          expr.is_a?(Hash) && expr.dig(:a_const, :isnull) == true
        end

        def parameterized?(hash)
          return true if hash.key?(:param_ref)

          hash.any? { |_, v| (v.is_a?(Hash) && parameterized?(v)) || (v.is_a?(Array) && v.any? { |e| e.is_a?(Hash) && parameterized?(e) }) }
        end

        # Keyword fallback when pg_query raises a parse error. Nothing beyond the kind of statement
        # is known here, so nothing it writes has been enumerated.
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
            parameterized: sql.match?(/\$\d+/), # fallback only; AST unavailable here
            write_columns_complete: false
          )
        end
      end
    end
  end
end
