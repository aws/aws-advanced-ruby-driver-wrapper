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
      @async_conn = nil
      @copy_conn = nil
      @lo_conn = nil
      conn_service = @service_container.connection_service
      @service_container.plugin_manager.connect(conn_service.initial_host_info, conn_service.driver_props, true)
    end

    # Every pg operation that talks to the server, and everything this class has to know about one: the
    # name the plugins see it under, the earlier call whose connection it can only be made on, and what
    # it leaves behind for the calls that follow it.
    #
    # An operation is described here rather than in the method that performs it, because there is more
    # than one way to reach it: as the method of its own name below, as one of the other spellings pg
    # gives it, or through method_missing. All three run {#execute_operation} against this entry, so an
    # operation cannot be given its bookkeeping down one of those paths and left without it down another.
    OPERATIONS = {
      exec: { method: RubyMethod::CONNECTION_EXEC },
      async_exec: { method: RubyMethod::CONNECTION_ASYNC_EXEC },
      exec_params: { method: RubyMethod::CONNECTION_EXEC_PARAMS },
      transaction: { method: RubyMethod::CONNECTION_TRANSACTION },
      close: { method: RubyMethod::CONNECTION_CLOSE },
      reset: { method: RubyMethod::CONNECTION_RESET },
      reset_start: { method: RubyMethod::CONNECTION_RESET_START },
      reset_poll: { method: RubyMethod::CONNECTION_RESET_POLL },

      # A prepared statement only exists on the connection it was prepared on.
      prepare: { method: RubyMethod::CONNECTION_PREPARE, after: :remember_prepared },
      send_prepare: { method: RubyMethod::CONNECTION_SEND_PREPARE, after: %i[remember_prepared remember_async] },
      exec_prepared: { method: RubyMethod::CONNECTION_EXEC_PREPARED, bound_to: :prepared },
      describe_prepared: { method: RubyMethod::CONNECTION_DESCRIBE_PREPARED, bound_to: :prepared },
      send_query_prepared: { method: RubyMethod::CONNECTION_SEND_QUERY_PREPARED, bound_to: :prepared, after: :remember_async },
      send_describe_prepared: { method: RubyMethod::CONNECTION_SEND_DESCRIBE_PREPARED, bound_to: :prepared, after: :remember_async },
      close_prepared: { method: RubyMethod::CONNECTION_CLOSE_PREPARED, bound_to: :prepared, after: :forget_prepared },

      # A pending exchange, and the portal it may have left, can only be continued on the connection it
      # was started on.
      send_query: { method: RubyMethod::CONNECTION_SEND_QUERY, after: :remember_async },
      send_query_params: { method: RubyMethod::CONNECTION_SEND_QUERY_PARAMS, after: :remember_async },
      get_result: { method: RubyMethod::CONNECTION_GET_RESULT, bound_to: :async, after: :forget_async_when_drained },
      get_last_result: { method: RubyMethod::CONNECTION_GET_LAST_RESULT, bound_to: :async, after: :forget_async },
      describe_portal: { method: RubyMethod::CONNECTION_DESCRIBE_PORTAL, bound_to: :async },
      close_portal: { method: RubyMethod::CONNECTION_CLOSE_PORTAL, bound_to: :async },
      send_describe_portal: { method: RubyMethod::CONNECTION_SEND_DESCRIBE_PORTAL, bound_to: :async, after: :remember_async },
      send_flush_request: { method: RubyMethod::CONNECTION_SEND_FLUSH_REQUEST, bound_to: :async, after: :remember_async },
      pipeline_sync: { method: RubyMethod::CONNECTION_PIPELINE_SYNC, bound_to: :async },
      send_pipeline_sync: { method: RubyMethod::CONNECTION_SEND_PIPELINE_SYNC, bound_to: :async, after: :remember_async },
      discard_results: { method: RubyMethod::CONNECTION_DISCARD_RESULTS, bound_to: :async, after: :forget_async },
      block: { method: RubyMethod::CONNECTION_BLOCK, bound_to: :async },

      # A COPY can only be fed or read on the connection it was started on.
      copy_data: { method: RubyMethod::CONNECTION_COPY_DATA },
      put_copy_data: { method: RubyMethod::CONNECTION_PUT_COPY_DATA, bound_to: :copy },
      get_copy_data: { method: RubyMethod::CONNECTION_GET_COPY_DATA, bound_to: :copy },
      put_copy_end: { method: RubyMethod::CONNECTION_PUT_COPY_END, bound_to: :copy, after: :forget_copy },

      cancel: { method: RubyMethod::CONNECTION_CANCEL },
      flush: { method: RubyMethod::CONNECTION_FLUSH },
      consume_input: { method: RubyMethod::CONNECTION_CONSUME_INPUT },
      notifies: { method: RubyMethod::CONNECTION_NOTIFIES },
      wait_for_notify: { method: RubyMethod::CONNECTION_WAIT_FOR_NOTIFY },
      encrypt_password: { method: RubyMethod::CONNECTION_ENCRYPT_PASSWORD },
      set_client_encoding: { method: RubyMethod::CONNECTION_SET_CLIENT_ENCODING },
      set_default_encoding: { method: RubyMethod::CONNECTION_SET_DEFAULT_ENCODING },
      'internal_encoding=': { method: RubyMethod::CONNECTION_INTERNAL_ENCODING_SET },

      # A large object descriptor is only open on the connection that opened it.
      lo_creat: { method: RubyMethod::CONNECTION_LO_CREAT },
      lo_create: { method: RubyMethod::CONNECTION_LO_CREATE },
      lo_import: { method: RubyMethod::CONNECTION_LO_IMPORT },
      lo_export: { method: RubyMethod::CONNECTION_LO_EXPORT },
      lo_unlink: { method: RubyMethod::CONNECTION_LO_UNLINK },
      lo_open: { method: RubyMethod::CONNECTION_LO_OPEN, after: :remember_large_object },
      lo_read: { method: RubyMethod::CONNECTION_LO_READ, bound_to: :large_object },
      lo_write: { method: RubyMethod::CONNECTION_LO_WRITE, bound_to: :large_object },
      lo_lseek: { method: RubyMethod::CONNECTION_LO_LSEEK, bound_to: :large_object },
      lo_tell: { method: RubyMethod::CONNECTION_LO_TELL, bound_to: :large_object },
      lo_truncate: { method: RubyMethod::CONNECTION_LO_TRUNCATE, bound_to: :large_object },
      lo_close: { method: RubyMethod::CONNECTION_LO_CLOSE, bound_to: :large_object, after: :forget_large_object }
    }.freeze

    # The operation each of the other names pg gives a call performs. The call enters the pipeline as
    # that operation, and the driver is asked for the name that was actually used, because a +sync_+ form
    # is not an alias: it is the blocking libpq call, where the +async_+ form sends the statement and then
    # waits on the socket from Ruby, so the wait can be interrupted. Which of the two a bare +exec+ means
    # is itself settable, through +PG::Connection.async_api=+, so performing one as the other would be
    # making a choice that belongs to the caller.
    #
    # A +sync_+ or +async_+ spelling that is missing here is still recognized, by {#operation_for}
    # removing the prefix. They are written out all the same, so that the list can be checked against the
    # gem, which the irregular ones below cannot be derived from at all.
    OPERATION_BY_SPELLING = {
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

    # Explicitly define critical methods (bypass method_missing to avoid method_missing overhead).
    # Each names the operation it performs and takes the arguments pg documents for it. The driver is
    # asked for the name of the operation unless the method says otherwise, as +query+ does. What the
    # operation entails is in {OPERATIONS}.

    def exec(sql, *params)
      execute_operation(:exec, [sql, *params])
    end

    # pg spells this operation +exec+, +query+, +async_exec+ and +async_query+, all of which run the
    # same libpq call. +query+ is defined here rather than left to method_missing because it is the
    # spelling applications use most after +exec+, and it enters the pipeline as +connection.exec+,
    # since that is the operation being performed. The name +connection.query+ is not used: that is
    # the mysql2 call, whose second argument is an options hash rather than a list of parameters.
    def query(sql, *params)
      execute_operation(:exec, [sql, *params], spelling: :query)
    end

    def exec_params(sql, params, result_format = 0, type_map = nil)
      execute_operation(:exec_params, [sql, params, result_format, type_map])
    end

    def async_exec(sql, *params)
      execute_operation(:async_exec, [sql, *params])
    end

    def transaction(&)
      execute_operation(:transaction, &)
    end

    def close
      execute_operation(:close)
    end

    alias finish close

    def reset
      execute_operation(:reset)
    end

    # -- Prepared statements --

    def prepare(stmt_name, sql, param_types = nil)
      execute_operation(:prepare, [stmt_name, sql, param_types])
    end

    def send_prepare(stmt_name, sql, param_types = nil)
      execute_operation(:send_prepare, [stmt_name, sql, param_types])
    end

    def exec_prepared(stmt_name, params = [], result_format = 0, type_map = nil)
      execute_operation(:exec_prepared, [stmt_name, params, result_format, type_map])
    end

    def describe_prepared(stmt_name)
      execute_operation(:describe_prepared, [stmt_name])
    end

    def send_query_prepared(stmt_name, params = [], result_format = 0, type_map = nil)
      execute_operation(:send_query_prepared, [stmt_name, params, result_format, type_map])
    end

    # -- Pending exchanges --

    def send_query(sql, *params)
      execute_operation(:send_query, [sql, *params])
    end

    def send_query_params(sql, params, result_format = 0, type_map = nil)
      execute_operation(:send_query_params, [sql, params, result_format, type_map])
    end

    def get_result # rubocop:disable Naming/AccessorMethodName
      execute_operation(:get_result)
    end

    def get_last_result # rubocop:disable Naming/AccessorMethodName
      execute_operation(:get_last_result)
    end

    # -- COPY --

    # The connection is held for as long as the block runs and let go afterward even if the block
    # raises, which is why this one keeps its own bookkeeping instead of leaving it to {OPERATIONS}.
    def copy_data(sql, coder = nil, &)
      @copy_conn = current_conn
      execute_operation(:copy_data, [sql, coder], &)
    ensure
      @copy_conn = nil
    end

    def put_copy_data(buffer, encoder = nil)
      execute_operation(:put_copy_data, [buffer, encoder])
    end

    def get_copy_data(async = false, decoder = nil)
      execute_operation(:get_copy_data, [async, decoder])
    end

    def put_copy_end(error_message = nil)
      execute_operation(:put_copy_end, [error_message])
    end

    # -- method_missing: covers non-network calls, the other spellings pg gives a call, and the network
    # calls that are rare enough not to be worth a method of their own --

    def method_missing(method_name, *args, **kwargs, &)
      conn = current_conn
      raise NoMethodError, 'Connection not initialized' if conn.nil?
      raise NoMethodError, "undefined method `#{method_name}' for #{self.class}" unless conn.respond_to?(method_name)

      operation = operation_for(method_name)
      return conn.send(method_name, *args, **kwargs, &) if operation.nil?

      execute_operation(operation, args, kwargs, spelling: method_name, &)
    end

    def respond_to_missing?(method, include_private = false)
      OPERATION_BY_SPELLING.key?(method) || current_conn.respond_to?(method, include_private) || super
    end

    private

    # Runs one operation through the pipeline: entered under the name the plugins know it by, refused if
    # what it needs was left on a connection that is no longer current, and followed by whatever it
    # leaves behind for the calls after it.
    #
    # The driver is asked for +spelling+, the name the call arrived under, which is not always the name
    # of the operation and so defaults to it. See {OPERATION_BY_SPELLING}.
    def execute_operation(operation, args = [], kwargs = {}, spelling: operation, &)
      spec = OPERATIONS[operation] || { method: "connection.#{operation}" }
      result = pm.execute(
        spec[:method], current_conn,
        ->(*a, **opts, &b) { current_conn.send(spelling, *a, **opts, &b) },
        *args, **kwargs, bounded_conn: bounded_conn_for(spec[:bound_to], args), &
      )
      Array(spec[:after]).each { |hook| send(hook, args, result) }
      wrap_pg_result(result)
    end

    # The operation a call performs, whatever spelling it arrived under, or nil for a call that does not
    # talk to the server and so has no business in the pipeline.
    def operation_for(spelling)
      operation = OPERATION_BY_SPELLING[spelling] || spelling
      return operation if OPERATIONS.key?(operation)

      # A spelling pg has added since {OPERATION_BY_SPELLING} was written. +sync_+ and +async_+ are its
      # own prefixes for the two ways it performs an operation, so whatever is left once one of them is
      # removed names that operation.
      stripped = spelling.to_s.sub(/\A(a?sync)_/, '').to_sym
      return stripped if OPERATIONS.key?(stripped)

      # Listed by the dialect but not described in {OPERATIONS}, which means the two have got out of
      # step. It still talks to the server, so it still goes through the plugins, under a name they can
      # match on, though without the bounded connection check that only a named method gets.
      spelling if network_bound_methods.include?("connection.#{spelling}")
    end

    # @return [Object, nil] the connection the operation is bound to, if it is bound to one
    def bounded_conn_for(bound_to, args)
      case bound_to
      when :prepared then @prepared_on[args.first]
      when :async then @async_conn
      when :copy then @copy_conn
      when :large_object then @lo_conn
      end
    end

    # -- What an operation leaves behind, named by the +after+ entries of {OPERATIONS} --

    def remember_prepared(args, _result)
      @prepared_on[args.first] = current_conn
    end

    def forget_prepared(args, _result)
      @prepared_on.delete(args.first)
    end

    def remember_async(_args, _result)
      @async_conn = current_conn
    end

    def forget_async(_args, _result)
      @async_conn = nil
    end

    # get_result answers nil once the last result of a pending exchange has been read, and there is
    # nothing left to be bound to.
    def forget_async_when_drained(_args, result)
      @async_conn = nil if result.nil?
    end

    def forget_copy(_args, _result)
      @copy_conn = nil
    end

    def remember_large_object(_args, _result)
      @lo_conn = current_conn
    end

    def forget_large_object(_args, _result)
      @lo_conn = nil
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

    def wrap_pg_result(result)
      return result unless result.is_a?(PG::Result)

      WrapperPgResult.new(result, @service_container, current_conn)
    end
  end

  class WrapperPgResult
    include Enumerable

    def initialize(result, service_container, connection)
      @result = result
      @service_container = service_container
      @connection = connection
    end

    def each(&)
      pm.execute(RubyMethod::RESULT_EACH, current_conn, ->(&blk) { @result.each(&blk) }, bounded_conn: @connection, &)
    end

    def each_row(&)
      pm.execute(RubyMethod::RESULT_EACH_ROW, current_conn, ->(&blk) { @result.each_row(&blk) }, bounded_conn: @connection, &)
    end

    def to_a
      pm.execute(RubyMethod::RESULT_TO_A, current_conn, -> { @result.to_a }, bounded_conn: @connection)
    end

    def [](index)
      pm.execute(RubyMethod::RESULT_BRACKET, current_conn, ->(*a) { @result[*a] }, index, bounded_conn: @connection)
    end

    def values
      pm.execute(RubyMethod::RESULT_VALUES, current_conn, -> { @result.values }, bounded_conn: @connection)
    end

    def column_values(index)
      pm.execute(RubyMethod::RESULT_COLUMN_VALUES, current_conn, ->(*a) { @result.column_values(*a) }, index, bounded_conn: @connection)
    end

    def field_values(field_name)
      pm.execute(RubyMethod::RESULT_FIELD_VALUES, current_conn, ->(*a) { @result.field_values(*a) }, field_name, bounded_conn: @connection)
    end

    def tuple(index)
      pm.execute(RubyMethod::RESULT_TUPLE, current_conn, ->(*a) { @result.tuple(*a) }, index, bounded_conn: @connection)
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
