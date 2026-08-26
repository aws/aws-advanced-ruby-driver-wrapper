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

require_relative 'driver_dialect'
require_relative '../host/connection_string_host_list_provider'

module AwsRubyDatabaseDriverWrapper
  module DriverDialects
    class MysqlDriverDialect
      include DriverDialect

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
        stmt.execute(*params)
      ensure
        stmt&.close
      end

      # mysql2 uses +?+ placeholders, so the SQL is already in its native form.
      def translate_placeholders(sql)
        sql
      end

      # mysql2 binds a blob parameter as raw binary bytes.
      def binary_param(bytes)
        bytes.b
      end

      # mysql2 hands back a blob column as a string that only needs its encoding forced to binary.
      def read_binary(value)
        value.b
      end

      # mysql2 reports the affected row count on the connection rather than the result.
      def affected_rows(connection, _result)
        connection.affected_rows.to_i
      end

      # mysql2 has no RETURNING clause, so the generated id is read from the connection afterwards.
      def insert_returning_id(connection, sql, params, _id_column)
        execute_with_params(connection, sql, params)
        id = connection.last_id
        id&.positive? ? id : nil
      end

      # mysql2 upserts with ON DUPLICATE KEY UPDATE, reading the incoming row from VALUES().
      def upsert_clause(_conflict_columns, update_columns)
        assignments = update_columns.map { |column| "#{column} = VALUES(#{column})" }.join(', ')
        "ON DUPLICATE KEY UPDATE #{assignments}"
      end

      def foreign_key_query
        'SELECT column_name AS from_column, referenced_table_name AS to_table, ' \
          'referenced_column_name AS to_column FROM information_schema.key_column_usage ' \
          'WHERE table_schema = ? AND table_name = ? AND referenced_table_name IS NOT NULL'
      end

      def ping(connection)
        connection.ping
      rescue StandardError
        false
      end

      def closed?(connection)
        connection.nil? || connection.closed?
      end

      def close_connection(connection)
        return if connection.nil? || connection.closed?

        connection.close
      rescue StandardError => e
        logger.error("Failed to close MySQL connection: #{e.message}")
      end

      def sql_state(exception)
        return nil unless exception.respond_to?(:sql_state)

        exception.sql_state
      end

      def network_bound_methods
        NETWORK_BOUND_METHODS
      end

      def prepare_connect_config(host_info, config)
        cfg = {}
        config.each { |k, v| cfg[k] = v }
        cfg[:host] = host_info.host if host_info.host_specified?
        cfg[:port] = host_info.port.to_i if host_info.port_specified?
        cfg
      end

      def user_property_key
        :username
      end

      def apply_monitoring_defaults(driver_props)
        # mysql2 read_timeout / write_timeout (in seconds) ensure that queries and closes
        # on a dead socket raise Mysql2::Error::TimeoutError instead of segfaulting.
        driver_props[:read_timeout] ||= DEFAULT_MONITORING_TIMEOUT_SEC
        driver_props[:write_timeout] ||= DEFAULT_MONITORING_TIMEOUT_SEC
        driver_props[:connect_timeout] ||= DEFAULT_MONITORING_TIMEOUT_SEC
      end
    end
  end
end
