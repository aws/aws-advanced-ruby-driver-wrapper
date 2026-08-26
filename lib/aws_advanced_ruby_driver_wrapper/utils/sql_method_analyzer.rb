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

require_relative '../ruby_method'

module AwsAdvancedRubyDriverWrapper
  module Utils
    module SqlMethodAnalyzer
      EXECUTE_SQL_METHODS = Set[
        RubyMethod::CONNECTION_EXEC.name,
        RubyMethod::CONNECTION_ASYNC_EXEC.name,
        RubyMethod::CONNECTION_EXEC_PARAMS.name,
        RubyMethod::CONNECTION_EXEC_PREPARED.name,
        RubyMethod::CONNECTION_QUERY.name,
        RubyMethod::CONNECTION_SEND_QUERY.name,
        RubyMethod::CONNECTION_SEND_QUERY_PARAMS.name,
        RubyMethod::STATEMENT_EXECUTE.name
      ].freeze

      CLOSE_TRANSACTION_METHODS = Set[
        RubyMethod::CONNECTION_CLOSE.name
      ].freeze

      QUOTE_CHARS = ["'", '"', '`'].freeze

      module_function

      def opens_transaction?(method_name, args, autocommit:, mysql_backslash_escapes: false)
        return false unless EXECUTE_SQL_METHODS.include?(method_name)

        sql = first_statement(args&.first, mysql_backslash_escapes: mysql_backslash_escapes)
        return false unless sql

        return true if starts_transaction?(sql)
        return true if !autocommit && opens_transaction_scope?(sql)

        false
      end

      def closes_transaction?(method_name, args, mysql_backslash_escapes: false)
        return true if CLOSE_TRANSACTION_METHODS.include?(method_name)
        return true if method_name == RubyMethod::CONNECTION_TRANSACTION.name
        return false unless EXECUTE_SQL_METHODS.include?(method_name)

        sql = first_statement(args&.first, mysql_backslash_escapes: mysql_backslash_escapes)
        return false unless sql

        ends_transaction?(sql)
      end

      def sets_autocommit?(method_name, args, mysql_backslash_escapes: false)
        return false unless EXECUTE_SQL_METHODS.include?(method_name)

        sql = first_statement(args&.first, mysql_backslash_escapes: mysql_backslash_escapes)
        return false unless sql

        sql.start_with?('SET AUTOCOMMIT')
      end

      def autocommit_value(args)
        sql = first_statement(args&.first)
        return nil unless sql

        sep = sql.index('=')
        if sep
          val_start = sep + 1
        else
          to_idx = sql.index(' TO ')
          return nil unless to_idx

          val_start = to_idx + 4
        end

        val = sql[val_start..].split(';', 2).first.strip
        case val
        when 'TRUE', '1', 'ON' then true
        when 'FALSE', '0', 'OFF' then false
        end
      end

      def first_statement(sql, mysql_backslash_escapes: false)
        return nil unless sql.is_a?(String) && !sql.strip.empty?

        stmts = strip_comments(sql, mysql_backslash_escapes: mysql_backslash_escapes).split(';')
        return nil if stmts.empty?

        stmts.first.squeeze(' ').strip.upcase(:ascii)
      end

      # Removes -- line comments, # line comments (MySQL), and /* */ block comments.
      # Quoted sections ('', "", ``, $$…$$) are preserved so comment markers inside strings are ignored.
      # Postgres nested block comments (/* /* */ */) are handled correctly.
      # Pass mysql_backslash_escapes: true to honour \ as an escape inside quoted strings.
      # Each comment is replaced by a single space to avoid merging adjacent tokens.
      def strip_comments(sql, mysql_backslash_escapes: false)
        result = +''
        i = 0
        len = sql.length
        while i < len
          c = sql[i]
          if c == '$' && (i + 1 < len) && (sql[i + 1] == '$' || sql[i + 1].match?(/[A-Za-z_]/)) &&
             (m = sql[i..].match(/\A(\$[^$]*\$)/n))
            # Postgres dollar-quoted string: $tag$...$tag$
            tag = m[1]
            close = sql.index(tag, i + tag.length)
            if close.nil?
              result << sql[i..]
              i = len
            else
              result << sql[i...(close + tag.length)]
              i = close + tag.length
            end
          elsif QUOTE_CHARS.include?(c)
            j = skip_quoted(sql, i, backslash_escapes: mysql_backslash_escapes)
            result << sql[i...j]
            i = j
          elsif c == '#' || (c == '-' && i + 1 < len && sql[i + 1] == '-')
            i = skip_to_end_of_line(sql, i)
            result << ' '
          elsif c == '/' && i + 1 < len && sql[i + 1] == '*'
            i = skip_block_comment(sql, i + 2)
            result << ' '
          else
            result << c
            i += 1
          end
        end
        result
      end

      def skip_block_comment(sql, start)
        depth = 1
        i = start
        len = sql.length
        while i < len && depth.positive?
          if sql[i] == '/' && sql[i + 1] == '*'
            depth += 1
            i += 2
          elsif sql[i] == '*' && sql[i + 1] == '/'
            depth -= 1
            i += 2
          else
            i += 1
          end
        end
        i
      end

      def skip_quoted(sql, start, backslash_escapes: false)
        quote = sql[start]
        i = start + 1
        while i < sql.length
          if backslash_escapes && sql[i] == '\\'
            i += 2
          elsif sql[i] == quote
            return i + 1 if i + 1 >= sql.length || sql[i + 1] != quote

            i += 2
          else
            i += 1
          end
        end
        sql.length
      end

      def skip_to_end_of_line(sql, start)
        i = start
        i += 1 while i < sql.length && sql[i] != "\n" && sql[i] != "\r"
        i
      end

      def starts_transaction?(stmt)
        stmt.start_with?('BEGIN', 'START TRANSACTION')
      end

      def ends_transaction?(stmt)
        stmt.start_with?('COMMIT', 'ROLLBACK', 'END', 'ABORT')
      end

      def opens_transaction_scope?(stmt)
        !starts_transaction?(stmt) && !ends_transaction?(stmt) &&
          !stmt.start_with?('SET ') && !stmt.start_with?('USE ') && !stmt.start_with?('SHOW ')
      end
    end
  end
end
