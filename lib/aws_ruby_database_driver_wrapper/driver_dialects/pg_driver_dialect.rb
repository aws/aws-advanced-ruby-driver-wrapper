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

module AwsRubyDatabaseDriverWrapper
  module DriverDialects
    class PgDriverDialect
      include DriverDialect

      PING_SQL = 'SELECT 1'

      NETWORK_BOUND_METHODS = (COMMON_NETWORK_BOUND_METHODS | Set[
        RubyMethod::CONNECTION_EXEC,
        RubyMethod::CONNECTION_ASYNC_EXEC,
        RubyMethod::CONNECTION_EXEC_PARAMS,
        RubyMethod::CONNECTION_EXEC_PREPARED,
        RubyMethod::CONNECTION_DESCRIBE_PREPARED,
        RubyMethod::CONNECTION_DESCRIBE_PORTAL,
        RubyMethod::CONNECTION_TRANSACTION,
        RubyMethod::CONNECTION_COPY_DATA,
        RubyMethod::CONNECTION_PUT_COPY_DATA,
        RubyMethod::CONNECTION_GET_COPY_DATA,
        RubyMethod::CONNECTION_PUT_COPY_END,
        RubyMethod::CONNECTION_SEND_QUERY,
        RubyMethod::CONNECTION_SEND_QUERY_PARAMS,
        RubyMethod::CONNECTION_SEND_QUERY_PREPARED,
        RubyMethod::CONNECTION_SEND_PREPARE,
        RubyMethod::CONNECTION_GET_RESULT,
        RubyMethod::CONNECTION_GET_LAST_RESULT,
        RubyMethod::CONNECTION_CANCEL,
        RubyMethod::CONNECTION_SET_CLIENT_ENCODING
      ]).freeze

      def connect(host_info, config)
        ::PG::Connection.new(**prepare_connect_config(host_info, config))
      end

      def execute(connection, sql)
        connection.exec(sql)
      end

      def ping(connection)
        connection.exec(PING_SQL)
        true
      rescue ::PG::Error
        false
      end

      def closed?(connection)
        connection.finished?
      end

      def close_connection(connection)
        connection.close
      rescue ::PG::Error => e
        logger.error("Failed to close PostgreSQL connection: #{e.message}")
      end

      def sql_state(exception)
        return nil unless exception.is_a?(::PG::Error) && exception.result

        exception.result.error_field(::PG::PG_DIAG_SQLSTATE)
      end

      def network_bound_methods
        NETWORK_BOUND_METHODS
      end

      def prepare_connect_config(host_info, config)
        cfg = config.dup
        cfg[:host] = host_info.host
        cfg[:port] = host_info.port if host_info.port_specified?
        cfg[:dbname] = cfg.delete(:database) if !cfg.key?(:dbname) && cfg.key?(:database)
        cfg
      end
    end
  end
end
