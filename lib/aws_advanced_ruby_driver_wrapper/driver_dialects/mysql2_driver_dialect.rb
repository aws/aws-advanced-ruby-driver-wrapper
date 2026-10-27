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

require_relative 'mysql_driver_dialect'

module AwsAdvancedRubyDriverWrapper
  module DriverDialects
    # How the mysql2 driver is called. The MySQL grammar and what every MySQL driver shares are
    # inherited.
    class Mysql2DriverDialect < MysqlDriverDialect
      # Every mysql2 call that talks to the server. A call that is not listed here is handed straight
      # to the driver, bypassing the plugin pipeline.
      #
      # Not listed, because libmysql answers them without talking to the server: escape, the row and
      # column counts, last_id, affected_rows, info, warning_count, thread_id, server_info,
      # session_track, and the connection's own settings.
      NETWORK_BOUND_METHODS = (COMMON_NETWORK_BOUND_METHODS | Set[
        RubyMethod::CONNECTION_QUERY.name,
        RubyMethod::CONNECTION_ASYNC_RESULT.name,
        RubyMethod::CONNECTION_SELECT_DB.name,
        RubyMethod::CONNECTION_MORE_RESULTS.name,
        RubyMethod::CONNECTION_NEXT_RESULT.name,
        RubyMethod::CONNECTION_STORE_RESULT.name,
        RubyMethod::CONNECTION_ABANDON_RESULTS.name,
        RubyMethod::CONNECTION_SET_SERVER_OPTION.name,
        RubyMethod::RESULT_EACH.name,
        RubyMethod::RESULT_FREE.name
      ]).freeze

      def connect(host_info, config)
        ::Mysql2::Client.new(**prepare_connect_config(host_info, config))
      end

      def execute(connection, sql)
        raise Mysql2::Error, 'MySQL client is not connected' if connection.nil? || connection.closed?

        connection.query(sql)
      end

      def execute_with_params(connection, sql, params)
        raise Mysql2::Error, 'MySQL client is not connected' if connection.nil? || connection.closed?

        stmt = connection.prepare(sql)
        result = stmt.execute(*params)
        # Everything the caller needs must be read off the statement before the ensure closes its
        # handle. A SELECT result is bound to the handle, so materialize its rows now - otherwise a
        # later iteration (e.g. SqlRunner calling #to_a) raises "Statement handle already closed".
        # A non-SELECT statement returns nil, and its affected-row count must come from the statement
        # too: once the handle is closed the connection-level mysql_affected_rows returns its -1 error
        # sentinel and mysql2 raises. So return that count for #affected_rows to hand back.
        result.is_a?(::Mysql2::Result) ? result.to_a : stmt.affected_rows
      ensure
        stmt&.close
      end

      # mysql2 binds a blob parameter as raw binary bytes.
      def binary_param(bytes)
        bytes.b
      end

      # mysql2 hands back a blob column as a string that only needs its encoding forced to binary.
      def read_binary(value)
        value.b
      end

      # A prepared statement (execute_with_params) hands back its own affected-row count, since the
      # connection-level count is unreadable once the statement handle is closed. A plain
      # connection.query (execute) leaves nil, so the count is read off the connection instead.
      def affected_rows(connection, result)
        result.is_a?(Integer) ? result : connection.affected_rows.to_i
      end

      # mysql2 has no RETURNING clause, so the generated id is read from the connection afterwards.
      def insert_returning_id(connection, sql, params, _id_column)
        execute_with_params(connection, sql, params)
        id = connection.last_id
        id&.positive? ? id : nil
      end

      # With automatic_close off, mysql2 invalidates the socket instead of sending COM_QUIT when
      # the client is collected, leaving the parent's session open.
      def abandon_connection(connection)
        return if connection.nil? || connection.closed?

        connection.automatic_close = false
      rescue StandardError => e
        logger.debug("Failed to abandon MySQL connection: #{e.message}")
      end

      def sql_state(exception)
        return nil unless exception.respond_to?(:sql_state)

        exception.sql_state
      end

      def network_bound_methods
        NETWORK_BOUND_METHODS
      end
    end
  end
end
