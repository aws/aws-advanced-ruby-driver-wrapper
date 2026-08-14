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

      # Every pg call that talks to the server. A call that is not listed here is handed straight
      # to the driver, bypassing the plugin pipeline.
      #
      # pg gives most of these operations several spellings (+query+ and +async_query+ for +exec+, an
      # +async_+ and a +sync_+ form for many others, a short +lo*+ form for every large object call).
      # One entry covers every spelling of an operation, because WrapperPgConnection translates the
      # alias to the canonical name before the pipeline is entered.
      #
      # Not listed, because libpq performs them without talking to the server: enter_pipeline_mode,
      # exit_pipeline_mode, is_busy, setnonblocking, set_single_row_mode, set_chunked_rows_mode, the
      # escaping and quoting calls, and the accessors for connection parameters and type maps.
      NETWORK_BOUND_METHODS = (COMMON_NETWORK_BOUND_METHODS | Set[
        RubyMethod::CONNECTION_EXEC.name,
        RubyMethod::CONNECTION_ASYNC_EXEC.name,
        RubyMethod::CONNECTION_EXEC_PARAMS.name,
        RubyMethod::CONNECTION_EXEC_PREPARED.name,
        RubyMethod::CONNECTION_DESCRIBE_PREPARED.name,
        RubyMethod::CONNECTION_DESCRIBE_PORTAL.name,
        RubyMethod::CONNECTION_TRANSACTION.name,
        RubyMethod::CONNECTION_COPY_DATA.name,
        RubyMethod::CONNECTION_PUT_COPY_DATA.name,
        RubyMethod::CONNECTION_GET_COPY_DATA.name,
        RubyMethod::CONNECTION_PUT_COPY_END.name,
        RubyMethod::CONNECTION_SEND_QUERY.name,
        RubyMethod::CONNECTION_SEND_QUERY_PARAMS.name,
        RubyMethod::CONNECTION_SEND_QUERY_PREPARED.name,
        RubyMethod::CONNECTION_SEND_PREPARE.name,
        RubyMethod::CONNECTION_GET_RESULT.name,
        RubyMethod::CONNECTION_GET_LAST_RESULT.name,
        RubyMethod::CONNECTION_CANCEL.name,
        RubyMethod::CONNECTION_SET_CLIENT_ENCODING.name,
        RubyMethod::CONNECTION_WAIT_FOR_NOTIFY.name,
        RubyMethod::CONNECTION_NOTIFIES.name,
        RubyMethod::CONNECTION_CONSUME_INPUT.name,
        RubyMethod::CONNECTION_FLUSH.name,
        RubyMethod::CONNECTION_LO_OPEN.name,
        RubyMethod::CONNECTION_LO_READ.name,
        RubyMethod::CONNECTION_LO_WRITE.name,
        RubyMethod::CONNECTION_LO_CLOSE.name,
        RubyMethod::CONNECTION_CLOSE_PREPARED.name,
        RubyMethod::CONNECTION_CLOSE_PORTAL.name,
        RubyMethod::CONNECTION_DISCARD_RESULTS.name,
        RubyMethod::CONNECTION_SEND_DESCRIBE_PREPARED.name,
        RubyMethod::CONNECTION_SEND_DESCRIBE_PORTAL.name,
        RubyMethod::CONNECTION_SEND_FLUSH_REQUEST.name,
        RubyMethod::CONNECTION_PIPELINE_SYNC.name,
        RubyMethod::CONNECTION_SEND_PIPELINE_SYNC.name,
        RubyMethod::CONNECTION_BLOCK.name,
        RubyMethod::CONNECTION_RESET_START.name,
        RubyMethod::CONNECTION_RESET_POLL.name,
        RubyMethod::CONNECTION_ENCRYPT_PASSWORD.name,
        RubyMethod::CONNECTION_SET_DEFAULT_ENCODING.name,
        RubyMethod::CONNECTION_INTERNAL_ENCODING_SET.name,
        RubyMethod::CONNECTION_LO_CREAT.name,
        RubyMethod::CONNECTION_LO_CREATE.name,
        RubyMethod::CONNECTION_LO_IMPORT.name,
        RubyMethod::CONNECTION_LO_EXPORT.name,
        RubyMethod::CONNECTION_LO_UNLINK.name,
        RubyMethod::CONNECTION_LO_LSEEK.name,
        RubyMethod::CONNECTION_LO_TELL.name,
        RubyMethod::CONNECTION_LO_TRUNCATE.name
      ]).freeze

      def connect(host_info, config)
        ::PG::Connection.new(**prepare_connect_config(host_info, config))
      end

      def execute(connection, sql)
        connection.exec(sql)
      end

      def execute_with_params(connection, sql, params)
        connection.exec_params(sql, params)
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
        return if connection.finished?

        connection.close
      rescue StandardError => e
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
        cfg = {}
        config.each { |k, v| cfg[k] = v }
        cfg[:host] = host_info.host if host_info.host_specified?
        cfg[:port] = host_info.port if host_info.port_specified?
        cfg[:dbname] = cfg.delete(:database) if !cfg.key?(:dbname) && cfg.key?(:database)
        cfg
      end

      def apply_monitoring_defaults(driver_props)
        driver_props[:connect_timeout] ||= DEFAULT_MONITORING_TIMEOUT_SEC
      end
    end
  end
end
