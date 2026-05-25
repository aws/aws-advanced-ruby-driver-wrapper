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
    class MysqlDriverDialect
      include DriverDialect

      NETWORK_BOUND_METHODS = (COMMON_NETWORK_BOUND_METHODS | Set[
        RubyMethod::CONNECTION_QUERY,
        RubyMethod::CONNECTION_QUERY_ASYNC,
        RubyMethod::CONNECTION_SELECT_DB,
        RubyMethod::CONNECTION_MORE_RESULTS,
        RubyMethod::CONNECTION_NEXT_RESULT,
        RubyMethod::CONNECTION_STORE_RESULT,
        RubyMethod::CONNECTION_ABANDON_RESULTS,
        RubyMethod::RESULT_EACH
      ]).freeze

      def connect(host_info, config)
        Mysql2::Client.new(**prepare_connect_config(host_info, config))
      end

      def execute(connection, sql)
        connection.query(sql)
      end

      def ping(connection)
        connection.ping
      rescue StandardError
        false
      end

      def closed?(connection)
        connection.closed?
      end

      def close_connection(connection)
        connection.close
      rescue StandardError => e
        LOGGER.error(format(LogMessages::FAILED_TO_CLOSE_MYSQL_CONNECTION, e.message))
      end

      def sql_state(exception)
        return nil unless exception.respond_to?(:sql_state)

        exception.sql_state
      end

      def network_bound_methods
        NETWORK_BOUND_METHODS
      end

      def prepare_connect_config(host_info, config)
        cfg = config.dup
        cfg[:host] = host_info.host
        cfg[:port] = host_info.port if host_info.port_specified?
        cfg
      end
    end
  end
end
