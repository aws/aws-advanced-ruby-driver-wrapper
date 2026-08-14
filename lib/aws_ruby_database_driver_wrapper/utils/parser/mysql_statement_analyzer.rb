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
      module MysqlStatementAnalyzer
        IDENTIFIER     = /`[^`]+`|"[^"]+"|\w+(?:\.\w+)*/
        IDENTIFIER_CAP = /(`[^`]+`|"[^"]+"|\w+(?:\.\w+)*)/
        IDENTIFIER_NC  = /(?:`[^`]+`|"[^"]+"|\w+(?:\.\w+)*)/ # non-capturing

        # REPLACE writes exactly like INSERT does, so it is read the same way.
        INSERT_INTO  = /\b(?:INSERT|REPLACE)\s+(?:IGNORE\s+)?INTO\s+#{IDENTIFIER_CAP}/i
        UPDATE_TABLE = /\bUPDATE\s+#{IDENTIFIER_CAP}/i
        DELETE_FROM  = /\bDELETE\s+FROM\s+#{IDENTIFIER_CAP}/i
        CREATE_TABLE = /\bCREATE\s+(?:TEMPORARY\s+)?TABLE\s+(?:IF\s+NOT\s+EXISTS\s+)?#{IDENTIFIER_CAP}/i
        DROP_TABLE   = /\bDROP\s+TABLE\s+(?:IF\s+EXISTS\s+)?#{IDENTIFIER_CAP}/i

        INSERT_COLUMNS = /\b(?:INSERT|REPLACE)\s+(?:IGNORE\s+)?INTO\s+(?:`[^`]+`|"[^"]+"|\w+(?:\.\w+)*)\s*\(([^)]+)\)/i
        SET_CLAUSE     = /\bSET\b([^;]+?)(?:\bWHERE\b|\z)/im
        VALUES_CLAUSE  = /\A\s*VALUES?\s*/i
        ON_DUPLICATE   = /\AON\s+DUPLICATE\s+KEY\s+UPDATE\b/i
        ASSIGNMENT     = /\A#{IDENTIFIER_CAP}\s*=\s*(.+)\z/m
        NULL_VALUE     = /\ANULL\z/i
        QUOTES         = ["'", '"', '`'].freeze
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
        INSERT_KEYWORD = /\A(?:INSERT|REPLACE)\b/
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
          bound, unbound, complete = extract_insert_columns(sql, table)
          QueryAnalysis.new(
            query_type: QueryType::INSERT,
            tables: table ? [table].freeze : [].freeze,
            write_columns: bound.freeze,
            where_columns: [].freeze,
            for_update: false,
            parameterized: sql.include?('?'),
            unbound_write_columns: unbound.freeze,
            write_columns_complete: complete
          )
        end

        def extract_update(sql)
          table = extract_first_capture(UPDATE_TABLE, sql)
          set_cols, unbound, complete = extract_set_columns(sql, table)
          where_cols = extract_where_columns(sql)
          QueryAnalysis.new(
            query_type: QueryType::UPDATE,
            tables: table ? [table].freeze : [].freeze,
            write_columns: set_cols.freeze,
            where_columns: where_cols.freeze,
            for_update: false,
            parameterized: sql.include?('?'),
            unbound_write_columns: unbound.freeze,
            write_columns_complete: complete
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

        # The columns an INSERT writes, each paired with the bind parameter that fills it.
        #
        # Both of the shapes MySQL accepts are read here: a column list followed by a VALUES clause,
        # and the +INSERT ... SET+ form. Anything else leaves the written columns unenumerated, since
        # without a column list the values are positional over the table's own column order, which
        # the statement does not carry, and with a nested SELECT the values never pass through the
        # client at all.
        #
        # @return [Array(Array<ColumnInfo>, Array<ColumnInfo>, Boolean)] the columns filled by a bind
        #   parameter, those filled by something else, and whether every written column was found
        def extract_insert_columns(sql, table_name)
          declared = INSERT_COLUMNS.match(sql)
          return extract_set_columns(sql, table_name) unless declared

          columns = split_top_level(declared[1])&.map { |column_token| strip_quotes(column_token) }
          rows, trailing = value_rows(sql[declared.end(0)..])
          return [[], [], false] if columns.nil? || rows.nil?

          bound = []
          unbound = []
          complete = true
          index = 1

          rows.each do |values|
            complete = false unless values.length == columns.length
            columns.each_with_index do |column_name, position|
              value = values[position]
              if value == '?'
                bound << ColumnInfo.new(table_name: table_name, column_name: column_name, parameter_index: index)
              elsif !NULL_VALUE.match?(value.to_s)
                unbound << ColumnInfo.new(table_name: table_name, column_name: column_name)
              end
              index += placeholder_count(value.to_s)
            end
            # A row with more values than columns is malformed, but its parameters are still counted
            # so that anything after it keeps the right index.
            values.drop(columns.length).each { |extra| index += placeholder_count(extra) }
          end

          upsert_bound, upsert_unbound, upsert_complete = extract_on_duplicate(trailing, table_name, index)
          [bound + upsert_bound, unbound + upsert_unbound, complete && upsert_complete]
        end

        # @return [Array(Array<ColumnInfo>, Array<ColumnInfo>, Boolean)] as extract_insert_columns
        def extract_set_columns(sql, table_name)
          match = SET_CLAUSE.match(sql)
          return [[], [], false] unless match

          bound, unbound, complete, = extract_assignments(match[1], table_name, 1)
          [bound, unbound, complete]
        end

        # What follows the value rows of an INSERT. An +ON DUPLICATE KEY UPDATE+ clause assigns to
        # columns just as a SET clause does, so it is read the same way. Anything else that neither
        # assigns nor binds - a row alias, a RETURNING list - writes nothing.
        #
        # @param index [Integer] the number of bind parameters that came before, plus one
        # @return [Array(Array<ColumnInfo>, Array<ColumnInfo>, Boolean)] as extract_insert_columns
        def extract_on_duplicate(trailing, table_name, index)
          text = trailing.to_s.strip.delete_suffix(';').strip
          return [[], [], true] if text.empty?

          match = ON_DUPLICATE.match(text)
          return [[], [], !text.include?('=') && !text.include?('?')] unless match

          bound, unbound, complete, = extract_assignments(text[match.end(0)..], table_name, index)
          [bound, unbound, complete]
        end

        # Reads a SET style clause, one +column = value+ per entry.
        #
        # @param index [Integer] the number of bind parameters that come before the clause, plus one
        # @return [Array(Array<ColumnInfo>, Array<ColumnInfo>, Boolean, Integer)] the columns
        #   assigned from a bind parameter, those assigned from something else, whether every
        #   assignment was read, and the index the next bind parameter would have
        def extract_assignments(clause, table_name, index)
          entries = split_top_level(clause)
          return [[], [], false, index] if entries.nil?

          bound = []
          unbound = []
          complete = true

          entries.each do |entry|
            match = ASSIGNMENT.match(entry)
            unless match
              complete = false
              index += placeholder_count(entry)
              next
            end

            value = match[2].strip
            column = ColumnInfo.new(table_name: table_name, column_name: strip_quotes(match[1]), parameter_index: index)
            if value == '?'
              bound << column
            elsif !NULL_VALUE.match?(value)
              unbound << column.with(parameter_index: nil)
            end
            index += placeholder_count(value)
          end

          [bound, unbound, complete, index]
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

        # -- Reading the text without a grammar --
        #
        # MySQL has no parser here the way PostgreSQL does, so the value lists have to be walked by
        # hand. All of this refuses to guess: text it cannot take apart is reported as such rather
        # than half read, since a caller deciding whether a column is written in the clear needs to
        # know the difference.

        # The parenthesised rows of a VALUES clause.
        #
        # @param text [String] what follows the column list
        # @return [Array(Array<Array<String>>, String), nil] one array of value expressions per row,
        #   and the text that follows the last of them; nil when the text is not a VALUES clause or
        #   cannot be taken apart
        def value_rows(text)
          return [nil, nil] unless text.to_s.match?(VALUES_CLAUSE)

          rest = text.sub(VALUES_CLAUSE, '')
          rows = []
          loop do
            body, rest = balanced_group(rest)
            return [nil, nil] if body.nil?

            values = split_top_level(body)
            return [nil, nil] if values.nil?

            rows << values
            rest = rest.lstrip
            break unless rest.start_with?(',')

            rest = rest[1..]
          end

          [rows, rest]
        end

        # Splits a leading +(...)+ off the text.
        #
        # @return [Array(String, String)] what was inside the parentheses and what follows it, or a
        #   pair of nils when the text does not begin with a balanced group
        def balanced_group(text)
          group = text.lstrip
          return [nil, nil] unless group.start_with?('(')

          depth = 0
          closed_at = nil
          unclosed_quote = each_unquoted_char(group) do |char, index|
            next if closed_at

            case char
            when '(' then depth += 1
            when ')'
              depth -= 1
              closed_at = index if depth.zero?
            end
          end
          return [nil, nil] if unclosed_quote || closed_at.nil?

          [group[1...closed_at], group[(closed_at + 1)..]]
        end

        # Splits a comma separated list, ignoring commas inside quotes or nested parentheses.
        #
        # @return [Array<String>, nil] nil when the quotes or parentheses do not balance
        def split_top_level(text)
          depth = 0
          boundaries = []
          unclosed_quote = each_unquoted_char(text) do |char, index|
            case char
            when '(' then depth += 1
            when ')' then depth -= 1
            when ',' then boundaries << index if depth.zero?
            end
          end
          return nil if unclosed_quote || !depth.zero?

          from = 0
          parts = boundaries.map do |at|
            part = text[from...at]
            from = at + 1
            part
          end
          (parts << text[from..]).map(&:strip)
        end

        # How many bind parameters a value expression consumes. A question mark inside a quoted
        # literal is not one of them.
        def placeholder_count(text)
          count = 0
          each_unquoted_char(text) { |char, _index| count += 1 if char == '?' }
          count
        end

        # Walks the text once, yielding every character that is not inside a quoted literal along
        # with its index. Backslash escapes are skipped, and a doubled quote reads as one closing and
        # one opening quote, which leaves the state right either way.
        #
        # @return [String, nil] the quote character still open when the text ran out, nil when the
        #   text ended outside a quoted literal
        def each_unquoted_char(text)
          index = 0
          quote = nil

          while index < text.length
            char = text[index]
            if quote
              if char == '\\' && quote != '`'
                index += 2
                next
              end

              quote = nil if char == quote
            elsif QUOTES.include?(char)
              quote = char
            else
              yield(char, index)
            end
            index += 1
          end

          quote
        end
      end
    end
  end
end
