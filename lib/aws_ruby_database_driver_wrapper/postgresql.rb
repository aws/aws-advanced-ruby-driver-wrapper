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
      @lo_conn = nil
      conn_service = @service_container.connection_service
      @service_container.plugin_manager.connect(conn_service.initial_host_info, conn_service.driver_props, true)
    end

    # Explicitly define critical methods (bypass method_missing to avoid method_missing overhead).

    def exec(sql, *params)
      result = pm.execute(RubyMethod::CONNECTION_EXEC, current_conn, ->(*a) { current_conn.exec(*a) }, sql, *params, sql: sql)
      wrap_pg_result(result, sql)
    end

    # pg spells this operation +exec+, +query+, +async_exec+ and +async_query+, all of which run the
    # same libpq call. +query+ is defined here rather than left to method_missing because it is the
    # spelling applications use most after +exec+, and it enters the pipeline as +connection.exec+,
    # since that is the operation being performed. The name +connection.query+ is not used: that is
    # the mysql2 call, whose second argument is an options hash rather than a list of parameters.
    def query(sql, *params)
      result = pm.execute(RubyMethod::CONNECTION_EXEC, current_conn, ->(*a) { current_conn.query(*a) }, sql, *params, sql: sql)
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

    # pg has no ping of its own: PG::Connection.ping is a class method that opens a connection of its
    # own to try a set of options out, and there is no instance method behind it. Asking the dialect
    # keeps the answer the same as everywhere else in the wrapper, which is whether a trivial
    # statement comes back.
    def ping
      pm.execute(RubyMethod::CONNECTION_PING, current_conn, -> { driver_dialect.ping(current_conn) })
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

    # -- method_missing: includes rarely used network calls and non-network calls that bypass the plugin pipeline --

    # The other spellings pg gives to a call that is defined above, or to one that is named in
    # {DYNAMIC_METHODS}. Each is the same operation, so it is performed by the canonical method and
    # enters the pipeline under that method's name, which is what gives it the statement's SQL and
    # the bookkeeping that goes with it.
    #
    # A +sync_+ form is therefore performed the way its canonical method performs it, which for a
    # statement is the asynchronous libpq call. The two do the same work; the asynchronous one lets
    # Ruby interrupt the wait, which is what a plugin needs in order to act on a connection that has
    # stopped answering.
    ALIASED_METHODS = {
      async_query: :exec, sync_exec: :exec,
      async_exec_params: :exec_params, sync_exec_params: :exec_params,
      async_exec_prepared: :exec_prepared, sync_exec_prepared: :exec_prepared,
      async_prepare: :prepare, sync_prepare: :prepare,
      async_describe_prepared: :describe_prepared, sync_describe_prepared: :describe_prepared,
      async_describe_portal: :describe_portal, sync_describe_portal: :describe_portal,
      async_get_result: :get_result, sync_get_result: :get_result,
      async_get_last_result: :get_last_result, sync_get_last_result: :get_last_result,
      async_put_copy_data: :put_copy_data, sync_put_copy_data: :put_copy_data,
      async_get_copy_data: :get_copy_data, sync_get_copy_data: :get_copy_data,
      async_put_copy_end: :put_copy_end, sync_put_copy_end: :put_copy_end,
      async_reset: :reset, sync_reset: :reset,
      async_cancel: :cancel, sync_cancel: :cancel,
      async_flush: :flush, sync_flush: :flush,
      async_close_prepared: :close_prepared, sync_close_prepared: :close_prepared,
      async_close_portal: :close_portal, sync_close_portal: :close_portal,
      async_pipeline_sync: :pipeline_sync, sync_pipeline_sync: :pipeline_sync,
      async_encrypt_password: :encrypt_password, sync_encrypt_password: :encrypt_password,
      async_set_client_encoding: :set_client_encoding, sync_set_client_encoding: :set_client_encoding,
      'client_encoding=': :set_client_encoding,
      notifies_wait: :wait_for_notify,
      locreat: :lo_creat, locreate: :lo_create, loimport: :lo_import, loexport: :lo_export,
      lounlink: :lo_unlink, loopen: :lo_open, loread: :lo_read, lowrite: :lo_write,
      loclose: :lo_close, lolseek: :lo_lseek, lo_seek: :lo_lseek, loseek: :lo_lseek,
      lotell: :lo_tell, lotruncate: :lo_truncate
    }.freeze

    # The network calls that are rare enough not to be worth a method of their own. They are entered
    # into the pipeline under the name the pipeline knows them by rather than as a bare string, so
    # that the connection each is bound to is checked.
    DYNAMIC_METHODS = {
      describe_portal: RubyMethod::CONNECTION_DESCRIBE_PORTAL,
      close_prepared: RubyMethod::CONNECTION_CLOSE_PREPARED,
      close_portal: RubyMethod::CONNECTION_CLOSE_PORTAL,
      send_describe_prepared: RubyMethod::CONNECTION_SEND_DESCRIBE_PREPARED,
      send_describe_portal: RubyMethod::CONNECTION_SEND_DESCRIBE_PORTAL,
      send_flush_request: RubyMethod::CONNECTION_SEND_FLUSH_REQUEST,
      discard_results: RubyMethod::CONNECTION_DISCARD_RESULTS,
      pipeline_sync: RubyMethod::CONNECTION_PIPELINE_SYNC,
      send_pipeline_sync: RubyMethod::CONNECTION_SEND_PIPELINE_SYNC,
      block: RubyMethod::CONNECTION_BLOCK,
      cancel: RubyMethod::CONNECTION_CANCEL,
      flush: RubyMethod::CONNECTION_FLUSH,
      consume_input: RubyMethod::CONNECTION_CONSUME_INPUT,
      notifies: RubyMethod::CONNECTION_NOTIFIES,
      wait_for_notify: RubyMethod::CONNECTION_WAIT_FOR_NOTIFY,
      reset_start: RubyMethod::CONNECTION_RESET_START,
      reset_poll: RubyMethod::CONNECTION_RESET_POLL,
      encrypt_password: RubyMethod::CONNECTION_ENCRYPT_PASSWORD,
      set_client_encoding: RubyMethod::CONNECTION_SET_CLIENT_ENCODING,
      set_default_encoding: RubyMethod::CONNECTION_SET_DEFAULT_ENCODING,
      'internal_encoding=': RubyMethod::CONNECTION_INTERNAL_ENCODING_SET,
      lo_creat: RubyMethod::CONNECTION_LO_CREAT,
      lo_create: RubyMethod::CONNECTION_LO_CREATE,
      lo_import: RubyMethod::CONNECTION_LO_IMPORT,
      lo_export: RubyMethod::CONNECTION_LO_EXPORT,
      lo_unlink: RubyMethod::CONNECTION_LO_UNLINK,
      lo_open: RubyMethod::CONNECTION_LO_OPEN,
      lo_read: RubyMethod::CONNECTION_LO_READ,
      lo_write: RubyMethod::CONNECTION_LO_WRITE,
      lo_close: RubyMethod::CONNECTION_LO_CLOSE,
      lo_lseek: RubyMethod::CONNECTION_LO_LSEEK,
      lo_tell: RubyMethod::CONNECTION_LO_TELL,
      lo_truncate: RubyMethod::CONNECTION_LO_TRUNCATE
    }.freeze

    # Calls that can only be made on the connection an earlier call left something on: a prepared
    # statement, a portal or a pending exchange, or an open large object descriptor.
    BOUNDED_TO_PREPARED = Set[:close_prepared, :send_describe_prepared].freeze
    BOUNDED_TO_ASYNC = Set[:describe_portal, :close_portal, :send_describe_portal, :send_flush_request,
                           :pipeline_sync, :send_pipeline_sync, :discard_results, :block].freeze
    BOUNDED_TO_LARGE_OBJECT = Set[:lo_read, :lo_write, :lo_lseek, :lo_tell, :lo_truncate, :lo_close].freeze

    def method_missing(method_name, *args, **kwargs, &)
      canonical = ALIASED_METHODS[method_name]
      return send(canonical, *args, **kwargs, &) if canonical

      conn = current_conn
      raise NoMethodError, 'Connection not initialized' if conn.nil?
      raise NoMethodError, "undefined method `#{method_name}' for #{self.class}" unless conn.respond_to?(method_name)

      method_key = "connection.#{method_name}"
      return conn.send(method_name, *args, **kwargs, &) unless network_bound_methods.include?(method_key)

      execute_dynamic(method_name, method_key, args, kwargs, &)
    end

    def respond_to_missing?(method, include_private = false)
      ALIASED_METHODS.key?(method) || current_conn.respond_to?(method, include_private) || super
    end

    private

    # Runs a call that reached method_missing through the pipeline, telling the plugins the SQL it
    # carries and the connection it is bound to, both of which are known here rather than from the
    # arguments of the call.
    def execute_dynamic(method_name, method_key, args, kwargs, &)
      bounded_conn, sql = pipeline_state_for(method_name, args)
      result = pm.execute(
        DYNAMIC_METHODS[method_name] || method_key, current_conn,
        ->(*a, **opts, &b) { current_conn.send(method_name, *a, **opts, &b) },
        *args, **kwargs, bounded_conn: bounded_conn, sql: sql, &
      )
      record_state_after(method_name, args)
      wrap_pg_result(result, sql)
    end

    # @return [Array(Object, String, nil)] the connection the call is bound to and the SQL it carries
    def pipeline_state_for(method_name, args)
      if BOUNDED_TO_PREPARED.include?(method_name)
        [@prepared_on[args.first], @prepared_sql[args.first]]
      elsif BOUNDED_TO_ASYNC.include?(method_name)
        [@async_conn, @async_sql]
      elsif BOUNDED_TO_LARGE_OBJECT.include?(method_name)
        [@lo_conn, nil]
      else
        [nil, nil]
      end
    end

    # Keeps track of what a call through method_missing leaves behind, so that whatever is done with
    # it next knows which connection it belongs to.
    def record_state_after(method_name, args)
      case method_name
      when :lo_open then @lo_conn = current_conn
      when :lo_close then @lo_conn = nil
      when :close_prepared
        @prepared_on.delete(args.first)
        @prepared_sql.delete(args.first)
      when :send_describe_prepared
        @async_conn = current_conn
        @async_sql = @prepared_sql[args.first]
      when :send_describe_portal, :send_pipeline_sync, :send_flush_request
        @async_conn = current_conn
      when :discard_results
        @async_conn = nil
        @async_sql = nil
      end
    end

    def current_conn
      @service_container.connection_service.current_connection
    end

    def pm
      @service_container.plugin_manager
    end

    def driver_dialect
      @service_container.dialect_service.driver_dialect
    end

    def network_bound_methods
      @network_bound_methods ||= driver_dialect.network_bound_methods
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
