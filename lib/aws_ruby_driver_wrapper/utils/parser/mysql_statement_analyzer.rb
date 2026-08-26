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

module AwsRubyDriverWrapper
  module Utils
    module Parser
      module MysqlStatementAnalyzer
        IDENTIFIER     = /`[^`]+`|"[^"]+"|\w+(?:\.\w+)*/
        IDENTIFIER_CAP = /(`[^`]+`|"[^"]+"|\w+(?:\.\w+)*)/
        IDENTIFIER_NC  = /(?:`[^`]+`|"[^"]+"|\w+(?:\.\w+)*)/ # non-capturing

        INSERT_INTO  = /\bINSERT\s+(?:IGNORE\s+)?INTO\s+#{IDENTIFIER_CAP}/i
        UPDATE_TABLE = /\bUPDATE\s+#{IDENTIFIER_CAP}/i
        DELETE_FROM  = /\bDELETE\s+FROM\s+#{IDENTIFIER_CAP}/i
        CREATE_TABLE = /\bCREATE\s+(?:TEMPORARY\s+)?TABLE\s+(?:IF\s+NOT\s+EXISTS\s+)?#{IDENTIFIER_CAP}/i
        DROP_TABLE   = /\bDROP\s+TABLE\s+(?:IF\s+EXISTS\s+)?#{IDENTIFIER_CAP}/i

        INSERT_COLUMNS = /\bINSERT\s+(?:IGNORE\s+)?INTO\s+(?:`[^`]+`|"[^"]+"|\w+(?:\.\w+)*)\s*\(([^)]+)\)/i
        SET_CLAUSE     = /\bSET\b([^;]+?)(?:\bWHERE\b|\z)/im
        WHERE_CLAUSE   = /
          \bWHERE\b([^;]+?)
          (?:\bGROUP\s+BY\b|\bHAVING\b|\bORDER\s+BY\b|\bLIMIT\b|
             \bFOR\s+(?:UPDATE|SHARE|NO\s+KEY\s+UPDATE|KEY\s+SHARE)\b|\z)
        /imx
        FOR_UPDATE     = /\bFOR\s+(?:UPDATE|SHARE|NO\s+KEY\s+UPDATE|KEY\s+SHARE)\b/i

        # Matches col = ? / col != ? / col > ? etc. in SET / WHERE
        COLUMN_PARAM   = /#{IDENTIFIER_CAP}\s*[=<>!]+\s*\?/
        # Matches col IN (?, ?, ...)
        COLUMN_IN      = /#{IDENTIFIER_CAP}\s+IN\s*\([^)]*\?[^)]*\)/i
        # Matches col LIKE ? / col NOT LIKE ?
        COLUMN_LIKE    = /#{IDENTIFIER_CAP}\s+(?:NOT\s+)?LIKE\s*\?/i
        # Matches col BETWEEN ? AND ? / col NOT BETWEEN ? AND ? (two params)
        COLUMN_BETWEEN = /#{IDENTIFIER_CAP}\s+(?:NOT\s+)?BETWEEN\s*\?\s+AND\s*\?/i

        # Single capture group 1 = column name; group 2 = :between sentinel when BETWEEN matched
        WHERE_PATTERN = /
          (#{IDENTIFIER_NC})
          \s+(?:NOT\s+)?BETWEEN\s*\?\s+AND\s*\?()
          |
          (#{IDENTIFIER_NC})\s*[=<>!]+\s*\?
          |
          (#{IDENTIFIER_NC})\s+IN\s*\([^)]*\?[^)]*\)
          |
          (#{IDENTIFIER_NC})\s+(?:NOT\s+)?LIKE\s*\?
        /imx

        FROM_TABLE     = /\bFROM\s+#{IDENTIFIER_CAP}/i
        JOIN_TABLE     = /\bJOIN\s+#{IDENTIFIER_CAP}/i

        SELECT_KEYWORD = /\ASELECT\b/
        INSERT_KEYWORD = /\AINSERT\b/
        UPDATE_KEYWORD = /\AUPDATE\b/
        DELETE_KEYWORD = /\ADELETE\b/
        CREATE_KEYWORD = /\ACREATE\b/
        DROP_KEYWORD   = /\ADROP\b/

        STRIP_QUOTES   = /\A[`"']|[`"']\z/

        module_function

        def analyze(sql)
          return QueryAnalysis.unknown unless sql.is_a?(String) && !sql&.strip&.empty?

          normalized_sql = sql.upcase.lstrip

          case normalized_sql
          when SELECT_KEYWORD then extract_select(sql)
          when INSERT_KEYWORD then extract_insert(sql)
          when UPDATE_KEYWORD then extract_update(sql)
          when DELETE_KEYWORD then extract_delete(sql)
          when CREATE_KEYWORD then extract_create(sql)
          when DROP_KEYWORD   then extract_drop(sql)
          else
            QueryAnalysis.unknown
          end
        end

        def extract_select(sql)
          tables = extract_all_tables(sql)
          where_cols = extract_where_columns(sql)
          QueryAnalysis.new(
            query_type: QueryType::SELECT,
            tables: tables.freeze,
            write_columns: [].freeze,
            where_columns: where_cols.freeze,
            for_update: FOR_UPDATE.match?(sql),
            parameterized: sql.include?('?')
          )
        end

        def extract_insert(sql)
          table = extract_first_capture(INSERT_INTO, sql)
          columns = extract_insert_columns(sql, table)
          QueryAnalysis.new(
            query_type: QueryType::INSERT,
            tables: table ? [table].freeze : [].freeze,
            write_columns: columns,
            where_columns: [].freeze,
            for_update: false,
            parameterized: sql.include?('?')
          )
        end

        def extract_update(sql)
          table = extract_first_capture(UPDATE_TABLE, sql)
          set_cols = extract_set_columns(sql, table)
          where_cols = extract_where_columns(sql)
          QueryAnalysis.new(
            query_type: QueryType::UPDATE,
            tables: table ? [table].freeze : [].freeze,
            write_columns: set_cols.freeze,
            where_columns: where_cols.freeze,
            for_update: false,
            parameterized: sql.include?('?')
          )
        end

        def extract_delete(sql)
          table = extract_first_capture(DELETE_FROM, sql)
          where_cols = extract_where_columns(sql)
          QueryAnalysis.new(
            query_type: QueryType::DELETE,
            tables: table ? [table].freeze : [].freeze,
            write_columns: [].freeze,
            where_columns: where_cols.freeze,
            for_update: false,
            parameterized: sql.include?('?')
          )
        end

        def extract_create(sql)
          table = extract_first_capture(CREATE_TABLE, sql)
          QueryAnalysis.new(
            query_type: QueryType::CREATE,
            tables: table ? [table].freeze : [].freeze,
            write_columns: [].freeze,
            where_columns: [].freeze,
            for_update: false,
            parameterized: false
          )
        end

        def extract_drop(sql)
          table = extract_first_capture(DROP_TABLE, sql)
          QueryAnalysis.new(
            query_type: QueryType::DROP,
            tables: table ? [table].freeze : [].freeze,
            write_columns: [].freeze,
            where_columns: [].freeze,
            for_update: false,
            parameterized: false
          )
        end

        def extract_first_capture(pattern, sql)
          match = pattern.match(sql)
          match && strip_quotes(match[1])
        end

        def extract_all_tables(sql)
          table_names = []
          sql.scan(FROM_TABLE) { table_names << strip_quotes(Regexp.last_match(1)) }
          sql.scan(JOIN_TABLE) { table_names << strip_quotes(Regexp.last_match(1)) }
          table_names.uniq.freeze
        end

        def extract_insert_columns(sql, table_name)
          match = INSERT_COLUMNS.match(sql)
          return [].freeze unless match

          match[1].split(',').map do |column_token|
            ColumnInfo.new(table_name: table_name, column_name: strip_quotes(column_token.strip))
          end.freeze
        end

        def extract_set_columns(sql, table_name)
          match = SET_CLAUSE.match(sql)
          return [].freeze unless match

          cols = []
          match[1].scan(COLUMN_PARAM) { cols << ColumnInfo.new(table_name: table_name, column_name: strip_quotes(Regexp.last_match(1))) }
          cols.freeze
        end

        def extract_where_columns(sql)
          match = WHERE_CLAUSE.match(sql)
          return [].freeze unless match

          where_body = match[1]
          return [].freeze unless where_body.include?('?')

          cols = []
          where_body.scan(WHERE_PATTERN) do
            m = Regexp.last_match
            # Groups: 1=BETWEEN col, 2=BETWEEN sentinel, 3=PARAM col, 4=IN col, 5=LIKE col
            col = strip_quotes((m[1] || m[3] || m[4] || m[5]).to_s)
            cols << ColumnInfo.new(table_name: nil, column_name: col)
            cols << ColumnInfo.new(table_name: nil, column_name: col) if m[1] # BETWEEN: two params
          end
          cols.freeze
        end

        def strip_quotes(identifier)
          identifier.gsub(STRIP_QUOTES, '')
        end
      end
    end
  end
end
