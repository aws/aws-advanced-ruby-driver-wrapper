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

require_relative 'utils/connection_config_parser'
require_relative 'services/service_utility'
require_relative 'ruby_method'
require_relative 'errors'

module AwsRubyDatabaseDriverWrapper
  class WrapperPgConnection
    class << self
      def new(*, **)
        instance = allocate
        instance.send(:initialize, *, **)
        instance
      end

      alias open new
      alias connect new
    end

    def initialize(*, **)
      config = Utils::ConnectionConfigParser.parse(:postgresql, *, **)
      @service_container = Services::ServiceUtility.create_standard_container(config)
      @service_container.host_service.refresh_host_list
      @prepared_on = {}
      @prepared_sql = {}
      @async_conn = nil
      @async_sql = nil
      @copy_conn = nil
      conn_service = @service_container.connection_service
      @service_container.plugin_manager.connect(conn_service.initial_host_info, conn_service.driver_props, true)
    end

    # Explicitly define critical methods (bypass method_missing to avoid method_missing overhead).

    def exec(sql, *params)
      result = pm.execute(RubyMethod::CONNECTION_EXEC, current_conn, ->(*a) { current_conn.exec(*a) }, sql, *params, sql: sql)
      wrap_pg_result(result, sql)
    end

    def exec_params(sql, params, result_format = 0, type_map = nil)
      result = pm.execute(
        RubyMethod::CONNECTION_EXEC_PARAMS, current_conn,
        ->(*a) { current_conn.exec_params(*a) },
        sql, params, result_format, type_map, sql: sql
      )
      wrap_pg_result(result, sql)
    end

    def async_exec(sql, *params)
      result = pm.execute(RubyMethod::CONNECTION_ASYNC_EXEC, current_conn, ->(*a) { current_conn.async_exec(*a) }, sql, *params,
                          sql: sql)
      wrap_pg_result(result, sql)
    end

    def transaction(&)
      pm.execute(RubyMethod::CONNECTION_TRANSACTION, current_conn, ->(&b) { current_conn.transaction(&b) }, &)
    end

    def close
      pm.execute(RubyMethod::CONNECTION_CLOSE, current_conn, -> { current_conn.close })
    end

    alias finish close

    def ping
      pm.execute(RubyMethod::CONNECTION_PING, current_conn, -> { current_conn.ping })
    end

    def reset
      pm.execute(RubyMethod::CONNECTION_RESET, current_conn, -> { current_conn.reset })
    end

    # -- Prepared statement writers (store @prepared_on) --

    def prepare(stmt_name, sql, param_types = nil)
      pm.execute(RubyMethod::CONNECTION_PREPARE, current_conn, ->(*a) { current_conn.prepare(*a) }, stmt_name, sql, param_types,
                 sql: sql)
      @prepared_on[stmt_name] = current_conn
      @prepared_sql[stmt_name] = sql
      nil
    end

    def send_prepare(stmt_name, sql, param_types = nil)
      pm.execute(RubyMethod::CONNECTION_SEND_PREPARE, current_conn, ->(*a) { current_conn.send_prepare(*a) }, stmt_name, sql,
                 param_types, sql: sql)
      @prepared_on[stmt_name] = current_conn
      @prepared_sql[stmt_name] = sql
      @async_conn = current_conn
    end

    # -- Prepared statement readers (check bounded to @prepared_on) --

    def exec_prepared(stmt_name, params = [], result_format = 0, type_map = nil)
      result = pm.execute(
        RubyMethod::CONNECTION_EXEC_PREPARED, current_conn,
        ->(*a) { current_conn.exec_prepared(*a) },
        stmt_name, params, result_format, type_map,
        bounded_conn: @prepared_on[stmt_name], sql: @prepared_sql[stmt_name]
      )
      wrap_pg_result(result, @prepared_sql[stmt_name])
    end

    def describe_prepared(stmt_name)
      result = pm.execute(
        RubyMethod::CONNECTION_DESCRIBE_PREPARED, current_conn,
        ->(*a) { current_conn.describe_prepared(*a) },
        stmt_name, bounded_conn: @prepared_on[stmt_name], sql: @prepared_sql[stmt_name]
      )
      wrap_pg_result(result, @prepared_sql[stmt_name])
    end

    # Cross-domain: reads @prepared_on, writes @async_conn
    def send_query_prepared(stmt_name, params = [], result_format = 0, type_map = nil)
      pm.execute(
        RubyMethod::CONNECTION_SEND_QUERY_PREPARED, current_conn,
        ->(*a) { current_conn.send_query_prepared(*a) },
        stmt_name, params, result_format, type_map,
        bounded_conn: @prepared_on[stmt_name], sql: @prepared_sql[stmt_name]
      )
      @async_conn = current_conn
      @async_sql = @prepared_sql[stmt_name]
    end

    # -- Async writers (store @async_conn) --

    def send_query(sql, *params)
      pm.execute(RubyMethod::CONNECTION_SEND_QUERY, current_conn, ->(*a) { current_conn.send_query(*a) }, sql, *params, sql: sql)
      @async_conn = current_conn
      @async_sql = sql
    end

    def send_query_params(sql, params, result_format = 0, type_map = nil)
      pm.execute(
        RubyMethod::CONNECTION_SEND_QUERY_PARAMS, current_conn,
        ->(*a) { current_conn.send_query_params(*a) },
        sql, params, result_format, type_map, sql: sql
      )
      @async_conn = current_conn
      @async_sql = sql
    end

    # -- Async readers (check bounded to @async_conn) --

    def get_result # rubocop:disable Naming/AccessorMethodName
      result = pm.execute(RubyMethod::CONNECTION_GET_RESULT, current_conn, -> { current_conn.get_result },
                          bounded_conn: @async_conn, sql: @async_sql)
      sql = @async_sql
      if result.nil?
        @async_conn = nil
        @async_sql = nil
      end
      wrap_pg_result(result, sql)
    end

    def get_last_result # rubocop:disable Naming/AccessorMethodName
      result = pm.execute(RubyMethod::CONNECTION_GET_LAST_RESULT, current_conn, lambda {
        current_conn.get_last_result
      }, bounded_conn: @async_conn, sql: @async_sql)
      sql = @async_sql
      @async_conn = nil
      @async_sql = nil
      wrap_pg_result(result, sql)
    end

    # -- COPY writer (store @copy_conn) --

    def copy_data(sql, coder = nil, &)
      @copy_conn = current_conn
      pm.execute(RubyMethod::CONNECTION_COPY_DATA, current_conn, ->(*a, &b) { current_conn.copy_data(*a, &b) }, sql, coder, &)
    ensure
      @copy_conn = nil
    end

    # -- COPY readers (check bounded to @copy_conn) --

    def put_copy_data(buffer, encoder = nil)
      pm.execute(
        RubyMethod::CONNECTION_PUT_COPY_DATA, current_conn,
        ->(*a) { current_conn.put_copy_data(*a) },
        buffer, encoder, bounded_conn: @copy_conn
      )
    end

    def get_copy_data(async = false, decoder = nil)
      pm.execute(
        RubyMethod::CONNECTION_GET_COPY_DATA, current_conn,
        ->(*a) { current_conn.get_copy_data(*a) },
        async, decoder, bounded_conn: @copy_conn
      )
    end

    def put_copy_end(error_message = nil)
      pm.execute(
        RubyMethod::CONNECTION_PUT_COPY_END, current_conn,
        ->(*a) { current_conn.put_copy_end(*a) },
        error_message, bounded_conn: @copy_conn
      )
      @copy_conn = nil
    end

    # -- method_missing: non-network bypasses pipeline --

    def method_missing(method_name, ...)
      conn = current_conn
      raise NoMethodError, 'Connection not initialized' if conn.nil?
      raise NoMethodError, "undefined method `#{method_name}' for #{self.class}" unless conn.respond_to?(method_name)

      method_key = "connection.#{method_name}"
      return conn.send(method_name, ...) unless network_bound_methods.include?(method_key)

      result = pm.execute(method_key, conn, ->(*a, **opts, &b) { current_conn.send(method_name, *a, **opts, &b) }, ...)
      wrap_pg_result(result)
    end

    def respond_to_missing?(method, include_private = false)
      current_conn.respond_to?(method, include_private) || super
    end

    private

    def current_conn
      @service_container.connection_service.current_connection
    end

    def pm
      @service_container.plugin_manager
    end

    def network_bound_methods
      @network_bound_methods ||= @service_container.dialect_service.driver_dialect.network_bound_methods
    end

    def wrap_pg_result(result, sql = nil)
      return result unless result.is_a?(PG::Result)

      WrapperPgResult.new(result, @service_container, current_conn, sql)
    end
  end

  class WrapperPgResult
    include Enumerable

    # @param sql [String, nil] the SQL that produced the result, kept so that plugins which
    #   inspect statements still see it when the rows are read
    def initialize(result, service_container, connection, sql = nil)
      @result = result
      @service_container = service_container
      @connection = connection
      @sql = sql
    end

    def each(&)
      pm.execute(RubyMethod::RESULT_EACH, current_conn, ->(&blk) { @result.each(&blk) }, bounded_conn: @connection, sql: @sql, &)
    end

    def each_row(&)
      pm.execute(RubyMethod::RESULT_EACH_ROW, current_conn, ->(&blk) { @result.each_row(&blk) }, bounded_conn: @connection, sql: @sql, &)
    end

    def to_a
      pm.execute(RubyMethod::RESULT_TO_A, current_conn, -> { @result.to_a }, bounded_conn: @connection, sql: @sql)
    end

    def [](index)
      pm.execute(RubyMethod::RESULT_BRACKET, current_conn, ->(*a) { @result[*a] }, index, bounded_conn: @connection, sql: @sql)
    end

    def values
      pm.execute(RubyMethod::RESULT_VALUES, current_conn, -> { @result.values }, bounded_conn: @connection, sql: @sql)
    end

    def column_values(index)
      pm.execute(RubyMethod::RESULT_COLUMN_VALUES, current_conn, ->(*a) { @result.column_values(*a) }, index,
                 bounded_conn: @connection, sql: @sql)
    end

    def field_values(field_name)
      pm.execute(RubyMethod::RESULT_FIELD_VALUES, current_conn, ->(*a) { @result.field_values(*a) }, field_name,
                 bounded_conn: @connection, sql: @sql)
    end

    def tuple(index)
      pm.execute(RubyMethod::RESULT_TUPLE, current_conn, ->(*a) { @result.tuple(*a) }, index, bounded_conn: @connection, sql: @sql)
    end

    # Delegate non-network methods directly
    def fields
      @result.fields
    end

    def ntuples
      @result.ntuples
    end

    def nfields
      @result.nfields
    end

    def cmd_tuples
      @result.cmd_tuples
    end

    def cmd_status
      @result.cmd_status
    end

    def result_status
      @result.result_status
    end

    def clear
      @result.clear
    end

    alias num_tuples ntuples
    alias count ntuples
    alias size ntuples

    def method_missing(method_name, *, &)
      @result.send(method_name, *, &)
    end

    def respond_to_missing?(method, include_private = false)
      @result.respond_to?(method, include_private) || super
    end

    private

    def current_conn
      @service_container.connection_service.current_connection
    end

    def pm
      @service_container.plugin_manager
    end
  end
end
