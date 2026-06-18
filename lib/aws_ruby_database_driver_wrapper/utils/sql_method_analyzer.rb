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

module AwsRubyDatabaseDriverWrapper
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

      module_function

      def opens_transaction?(method_name, args, autocommit:)
        return false unless EXECUTE_SQL_METHODS.include?(method_name)

        sql = first_statement(args&.first)
        return false unless sql

        return true if starts_transaction?(sql)
        return true if !autocommit && opens_transaction_scope?(sql)

        false
      end

      def closes_transaction?(method_name, args)
        return true if CLOSE_TRANSACTION_METHODS.include?(method_name)
        return true if method_name == RubyMethod::CONNECTION_TRANSACTION.name
        return false unless EXECUTE_SQL_METHODS.include?(method_name)

        sql = first_statement(args&.first)
        return false unless sql

        ends_transaction?(sql)
      end

      def sets_autocommit?(method_name, args)
        return false unless EXECUTE_SQL_METHODS.include?(method_name)

        sql = first_statement(args&.first)
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

      def first_statement(sql)
        return nil unless sql.is_a?(String) && !sql.strip.empty?

        stmt = sql.split(';', 2).first
        strip_block_comments(stmt).squeeze(' ').strip.upcase(:ascii)
      end

      def strip_block_comments(str)
        result = +''
        i = 0
        len = str.length
        while i < len
          if i + 1 < len && str[i] == '/' && str[i + 1] == '*'
            i += 2
            i += 1 while i + 1 < len && !(str[i] == '*' && str[i + 1] == '/')
            i += 2
          else
            result << str[i]
            i += 1
          end
        end
        result
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
