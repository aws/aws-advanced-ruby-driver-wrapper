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
        # One part of a name, quoted or not. MySQL quotes a part on its own, which is how it writes a
        # name that would otherwise be a reserved word.
        IDENTIFIER_PART = /(?:`[^`]+`|"[^"]+"|\w+)/
        # A name, in as many parts as it was written in: +ssn+, +u.ssn+, +`users`.`ssn`+,
        # +mydb.users.ssn+. The parts are spelled out rather than assuming that a quoted name is a
        # name of one part.
        IDENTIFIER_CAP  = /(#{IDENTIFIER_PART}(?:\.#{IDENTIFIER_PART})*)/
        IDENTIFIER_NC   = /(?:#{IDENTIFIER_PART}(?:\.#{IDENTIFIER_PART})*)/ # non-capturing

        # The modifiers MySQL allows between the keyword and the table it writes. They say how the
        # statement behaves, not what it writes, so the table has to be looked for past them: a
        # statement whose table went unread is one whose columns go unencrypted.
        # REPLACE writes exactly like INSERT does, so it is read the same way.
        INSERT_START = /\b(?:INSERT|REPLACE)\s+(?:(?:LOW_PRIORITY|HIGH_PRIORITY|DELAYED)\s+)?(?:IGNORE\s+)?INTO\s+/i
        UPDATE_START = /\bUPDATE\s+(?:LOW_PRIORITY\s+)?(?:IGNORE\s+)?/i

        INSERT_INTO  = /#{INSERT_START}#{IDENTIFIER_CAP}/i
        UPDATE_TABLE = /#{UPDATE_START}#{IDENTIFIER_CAP}/i
        DELETE_FROM  = /\bDELETE\s+FROM\s+#{IDENTIFIER_CAP}/i
        CREATE_TABLE = /\bCREATE\s+(?:TEMPORARY\s+)?TABLE\s+(?:IF\s+NOT\s+EXISTS\s+)?#{IDENTIFIER_CAP}/i
        DROP_TABLE   = /\bDROP\s+TABLE\s+(?:IF\s+EXISTS\s+)?#{IDENTIFIER_CAP}/i

        # Everything an UPDATE names between its keyword and its SET clause: one table reference, or
        # several when it writes more than one table.
        UPDATE_REFERENCES  = /#{UPDATE_START}(.*?)\bSET\b/im
        # What one table reference is joined to the next with. STRAIGHT_JOIN is spelled out because
        # there is no word boundary in front of the JOIN inside it.
        JOIN_KEYWORD       = /\bSTRAIGHT_JOIN\b|\bJOIN\b/i
        # The table a reference begins with, whatever follows it: an alias, an index hint, an ON
        # condition.
        LEADING_IDENTIFIER = /\A\s*#{IDENTIFIER_CAP}/

        INSERT_COLUMNS = /#{INSERT_START}#{IDENTIFIER_NC}\s*\(([^)]+)\)/i
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
        FOR_UPDATE = /\bFOR\s+(?:UPDATE|SHARE|NO\s+KEY\s+UPDATE|KEY\s+SHARE)\b/i

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

        # Whitespace and comments in front of a statement. Query instrumentation and ORMs prepend a
        # comment routinely, and it says nothing about what the statement does.
        LEADING_NOISE  = %r{\A(?:\s+|/\*.*?\*/|--[^\n]*|\#[^\n]*)+}m
        CTE_START      = /\AWITH\s+(?:RECURSIVE\s+)?/i
        CTE_NAME       = /\A#{IDENTIFIER_NC}\s*/
        CTE_AS         = /\AAS\s+(?:(?:NOT\s+)?MATERIALIZED\s*)?/i

        # Every part of a name can be quoted, so all of them are taken off rather than only the ones
        # at the ends: +`mydb`.`users`+ is the one table +mydb.users+.
        STRIP_QUOTES   = /[`"']/

        # A column named with something in front of it: +u.ssn+, +users.ssn+, +db.users.ssn+. Only
        # the last part is the column. A quoted identifier can hold a dot of its own, so the parts
        # are matched rather than split on, which keeps a column actually named +`a.b`+ intact.
        QUALIFIED_COLUMN = /\A(?:#{IDENTIFIER_PART}\.)+(#{IDENTIFIER_PART})\z/

        module_function

        def analyze(sql)
          return QueryAnalysis.unknown unless sql.is_a?(String) && !sql&.strip&.empty?

          body, preceding_parameters = statement_body(sql)
          return QueryAnalysis.unknown if body.nil?

          # A statement that writes is read from its keyword onwards, so that a value list belonging
          # to a common table expression is not mistaken for its own. A SELECT is read from the whole
          # text, so that the tables a common table expression reads are reported as well.
          case body.upcase
          when SELECT_KEYWORD then extract_select(sql)
          when INSERT_KEYWORD then extract_insert(body, preceding_parameters + 1)
          when UPDATE_KEYWORD then extract_update(body, preceding_parameters + 1)
          when DELETE_KEYWORD then extract_delete(body)
          when CREATE_KEYWORD then extract_create(body)
          when DROP_KEYWORD   then extract_drop(body)
          else
            QueryAnalysis.unknown
          end
        end

        # A statement with whatever precedes its keyword taken off.
        #
        # @return [Array(String, Integer)] the statement from its own keyword onwards, and the number
        #   of bind parameters that come before it; a pair of nils when what precedes the keyword
        #   cannot be read, since then neither the statement nor its parameter numbering is known
        def statement_body(sql)
          body = sql.sub(LEADING_NOISE, '')
          return [body, 0] unless CTE_START.match?(body)

          rest = cte_tail(body)
          return [nil, nil] if rest.nil?

          [rest.sub(LEADING_NOISE, ''), placeholder_count(body[0...(body.length - rest.length)])]
        end

        # Walks a +WITH+ clause, one +name [(columns)] AS (subquery)+ entry at a time.
        #
        # @return [String, nil] the text that follows the clause, or nil when an entry could not be
        #   taken apart
        def cte_tail(text)
          rest = text.sub(CTE_START, '')

          loop do
            rest = rest.sub(LEADING_NOISE, '')
            name = CTE_NAME.match(rest)
            return nil unless name

            rest = rest[name.end(0)..]
            rest = skip_group(rest) if rest.start_with?('(') # the entry names its own columns
            return nil if rest.nil?

            as_keyword = CTE_AS.match(rest)
            return nil unless as_keyword

            rest = skip_group(rest[as_keyword.end(0)..])
            return nil if rest.nil?

            rest = rest.lstrip
            break unless rest.start_with?(',')

            rest = rest[1..]
          end

          rest
        end

        # @return [String, nil] the text that follows a leading +(...)+, or nil when it is not
        #   balanced
        def skip_group(text)
          _group, rest = balanced_group(text)
          rest&.lstrip
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

        # @param first_index [Integer] the number the statement's first bind parameter has
        def extract_insert(sql, first_index = 1)
          table = extract_first_capture(INSERT_INTO, sql)
          bound, unbound, complete = extract_insert_columns(sql, table, first_index)
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

        # @param first_index [Integer] the number the statement's first bind parameter has
        def extract_update(sql, first_index = 1)
          references = UPDATE_REFERENCES.match(sql)&.[](1)
          return extract_multi_table_update(sql, references, first_index) if references && multiple_references?(references)

          table = extract_first_capture(UPDATE_TABLE, sql)
          set_cols, unbound, complete = extract_set_columns(sql, table, first_index)
          where_cols = extract_where_columns(sql, first_index)
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

        # Whether an UPDATE writes more than one table, which MySQL allows and which changes what an
        # assignment means: with two tables in front of it, +SET a.ssn = ?+ belongs to whichever of
        # them the reference list gave the name +a+ to, and that is more than this reader tracks.
        # A reference list it cannot split is counted as more than one reference for the same reason.
        def multiple_references?(references)
          return true if JOIN_KEYWORD.match?(references)

          entries = split_top_level(references)
          entries.nil? || entries.length > 1
        end

        # An UPDATE of more than one table, reported as a statement whose written columns could not be
        # enumerated. Attributing an assignment to the first table named would be a guess, and a wrong
        # guess either leaves a plaintext in an encrypted column or writes a value under a key nothing
        # reads it back with, so nothing is attributed at all. Every table the statement names is
        # reported, which is what lets a caller see whether any of them holds a column worth
        # protecting, and a column assigned something other than a bind parameter is reported without
        # its table, the column name being known even where it sits not being.
        #
        # @param first_index [Integer] the number the statement's first bind parameter has
        def extract_multi_table_update(sql, references, first_index)
          _bound, unbound, = extract_set_columns(sql, nil, first_index)
          QueryAnalysis.new(
            query_type: QueryType::UPDATE,
            tables: reference_tables(references).freeze,
            write_columns: [].freeze,
            where_columns: extract_where_columns(sql, first_index),
            for_update: false,
            parameterized: sql.include?('?'),
            unbound_write_columns: unbound.freeze,
            write_columns_complete: false
          )
        end

        # The tables a reference list names, as far as they can be read. A reference this cannot read
        # contributes nothing rather than a guess, and a list it reads nothing from leaves no tables at
        # all, which is what says the statement could not be placed anywhere.
        def reference_tables(references)
          (split_top_level(references) || [references])
            .flat_map { |entry| entry.split(JOIN_KEYWORD) }
            .filter_map { |fragment| extract_first_capture(LEADING_IDENTIFIER, fragment) }
            .uniq
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
        # @param first_index [Integer] the number the statement's first bind parameter has
        # @return [Array(Array<ColumnInfo>, Array<ColumnInfo>, Boolean)] the columns filled by a bind
        #   parameter, those filled by something else, and whether every written column was found
        def extract_insert_columns(sql, table_name, first_index = 1)
          declared = INSERT_COLUMNS.match(sql)
          return extract_set_columns(sql, table_name, first_index) unless declared

          columns = split_top_level(declared[1])&.map { |column_token| column_name_of(column_token) }
          rows, trailing = value_rows(sql[declared.end(0)..])
          return [[], [], false] if columns.nil? || rows.nil?

          bound = []
          unbound = []
          complete = true
          index = first_index

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

        # @param first_index [Integer] the number the statement's first bind parameter has
        # @return [Array(Array<ColumnInfo>, Array<ColumnInfo>, Boolean)] as extract_insert_columns
        def extract_set_columns(sql, table_name, first_index = 1)
          match = SET_CLAUSE.match(sql)
          return [[], [], false] unless match

          bound, unbound, complete, = extract_assignments(match[1], table_name, first_index)
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
            column = ColumnInfo.new(table_name: table_name, column_name: column_name_of(match[1]), parameter_index: index)
            if value == '?'
              bound << column
            elsif !NULL_VALUE.match?(value)
              unbound << column.with(parameter_index: nil)
            end
            index += placeholder_count(value)
          end

          [bound, unbound, complete, index]
        end

        # The columns a WHERE clause compares against a bind parameter, each paired with the parameter
        # that fills it. Unlike PostgreSQL, MySQL numbers its parameters positionally, so the index of
        # each one has to be counted rather than read: a parameter is numbered after everything that
        # comes before the clause - an UPDATE's SET assignments, a SELECT list, a CTE - and after every
        # parameter of an earlier predicate. Without this a clause is numbered from one and a parameter
        # that follows an unrecognised one, or a multi-value +IN (?, ?, ...)+, shifts every column after
        # it onto the wrong parameter.
        #
        # @param first_index [Integer] the number the statement's first bind parameter has
        def extract_where_columns(sql, first_index = 1)
          match = WHERE_CLAUSE.match(sql)
          return [].freeze unless match

          where_body = match[1]
          return [].freeze unless where_body.include?('?')

          base = first_index + placeholder_count(sql[0...match.begin(1)])

          cols = []
          where_body.scan(WHERE_PATTERN) do
            m = Regexp.last_match
            # Groups: 1=BETWEEN col, 2=BETWEEN sentinel, 3=PARAM col, 4=IN col, 5=LIKE col
            col = strip_quotes((m[1] || m[3] || m[4] || m[5]).to_s)
            index = base + placeholder_count(where_body[0...m.begin(0)])
            # One entry per bound parameter the predicate consumes: one for +=+ or +LIKE+, two for a
            # +BETWEEN+, and one per placeholder for an +IN (?, ?, ...)+.
            placeholder_count(m[0]).times do |offset|
              cols << ColumnInfo.new(table_name: nil, column_name: col, parameter_index: index + offset)
            end
          end
          cols.freeze
        end

        def strip_quotes(identifier)
          identifier.gsub(STRIP_QUOTES, '')
        end

        # The column an identifier names, with whatever qualifies it dropped.
        #
        # MySQL lets the target of an assignment carry a qualifier, +SET u.ssn = ?+, where +u+ is
        # either the table or an alias for it. Which of the two it is cannot be told from the text,
        # but a statement with one table to write can only mean that table either way, so only the
        # column name is kept. Where the qualifier would carry the answer, an UPDATE naming more than
        # one table, the assignments are not attributed at all: see +extract_multi_table_update+.
        def column_name_of(identifier)
          strip_quotes(QUALIFIED_COLUMN.match(identifier)&.[](1) || identifier)
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
