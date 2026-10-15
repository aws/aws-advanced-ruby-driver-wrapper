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

module AwsAdvancedRubyDriverWrapper
  module DriverDialects
    # What every MySQL driver shares: the server's SQL grammar, and the connection options and
    # connection calls the MySQL drivers name alike. A driver's own dialect subclasses this and adds
    # how the driver itself is called.
    class MysqlDriverDialect
      include DriverDialect

      def database_engine
        :mysql
      end

      # MySQL uses +?+ placeholders, so the SQL is already in its native form.
      def translate_placeholders(sql)
        sql
      end

      # MySQL upserts with ON DUPLICATE KEY UPDATE, reading the incoming row from VALUES().
      def upsert_clause(_conflict_columns, update_columns)
        assignments = update_columns.map { |column| "#{column} = VALUES(#{column})" }.join(', ')
        "ON DUPLICATE KEY UPDATE #{assignments}"
      end

      # MySQL has no user-defined operators, so the plain operator always means the built-in one.
      def equals_operator
        '='
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

      # Read, write and connect timeouts (in seconds) make a query or a close on a dead socket raise a
      # timeout error rather than hang. With mysql2 they also keep it from segfaulting.
      def apply_monitoring_defaults(driver_props)
        driver_props[:read_timeout] ||= DEFAULT_MONITORING_TIMEOUT_SEC
        driver_props[:write_timeout] ||= DEFAULT_MONITORING_TIMEOUT_SEC
        driver_props[:connect_timeout] ||= DEFAULT_MONITORING_TIMEOUT_SEC
      end
    end
  end
end
