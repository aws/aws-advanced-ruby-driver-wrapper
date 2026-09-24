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

module AwsAdvancedRubyDriverWrapper
  class WrapperPgConnection
    class << self
      def new(*, **)
        instance = allocate
        instance.send(:initialize, *, **)
        return instance unless block_given?

        begin
          yield instance
        ensure
          instance.close
        end
      end

      alias open new
      alias connect new
    end

    def initialize(*, **)
      ensure_pg!
      config = Utils::ConnectionConfigParser.parse(:postgresql, *, **)
      @service_container = Services::ServiceUtility.create_standard_container(config)
      @service_container.host_service.refresh_host_list
      @prepared_on = {}
      @prepared_sql = {}
      @async_conn = nil
      @async_sql = nil
      @copy_conn = nil
      @copy_sql = nil
      @lo_conn = nil
      conn_service = @service_container.connection_service
      @service_container.plugin_manager.connect(conn_service.initial_host_info, conn_service.driver_props, true)
    end

    # Every canonical pg operation that talks to the server, and everything this class has to know about one: the
    # name the plugins see it under, the connection it is bound to, where the SQL it carries is among its
    # arguments, and the steps that should be performed after.
    #
    # An operation with no +sql_at+ takes the SQL of whatever it is bound to: the statement a prepared
    # operation names, the statement a pending exchange was started with, or the statement a COPY was
    # opened with. That is the whole reason each of them is remembered, since none is among the arguments
    # of the call that reads it back.
    OPERATIONS = {
      exec: { method: RubyMethod::CONNECTION_EXEC, sql_at: 0, after: :remember_sql_prepared },
      async_exec: { method: RubyMethod::CONNECTION_ASYNC_EXEC, sql_at: 0, after: :remember_sql_prepared },
      exec_params: { method: RubyMethod::CONNECTION_EXEC_PARAMS, sql_at: 0, after: :remember_sql_prepared },
      transaction: { method: RubyMethod::CONNECTION_TRANSACTION },
      close: { method: RubyMethod::CONNECTION_CLOSE },
      reset: { method: RubyMethod::CONNECTION_RESET, after: :reset_session_state },
      reset_start: { method: RubyMethod::CONNECTION_RESET_START },
      reset_poll: { method: RubyMethod::CONNECTION_RESET_POLL },

      # A prepared statement only exists on the connection it was prepared on.
      prepare: { method: RubyMethod::CONNECTION_PREPARE, sql_at: 1, after: :remember_prepared },
      send_prepare: { method: RubyMethod::CONNECTION_SEND_PREPARE, sql_at: 1, after: %i[remember_prepared remember_async] },
      exec_prepared: { method: RubyMethod::CONNECTION_EXEC_PREPARED, bound_to: :prepared },
      describe_prepared: { method: RubyMethod::CONNECTION_DESCRIBE_PREPARED, bound_to: :prepared },
      send_query_prepared: { method: RubyMethod::CONNECTION_SEND_QUERY_PREPARED, bound_to: :prepared, after: :remember_async },
      send_describe_prepared: { method: RubyMethod::CONNECTION_SEND_DESCRIBE_PREPARED, bound_to: :prepared, after: :remember_async },
      close_prepared: { method: RubyMethod::CONNECTION_CLOSE_PREPARED, bound_to: :prepared, after: :forget_prepared },

      # A pending exchange, and the portal it may have left, can only be continued on the connection it
      # was started on.
      send_query: { method: RubyMethod::CONNECTION_SEND_QUERY, sql_at: 0, after: %i[remember_async remember_sql_prepared] },
      send_query_params: { method: RubyMethod::CONNECTION_SEND_QUERY_PARAMS, sql_at: 0,
                           after: %i[remember_async remember_sql_prepared] },
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
      copy_data: { method: RubyMethod::CONNECTION_COPY_DATA, sql_at: 0 },
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

    # pg gives most operations more than one spelling, and an application is free to use any of them. Each
    # spelling here is mapped to the operation it performs, so that spellings enter the pipeline under one
    # canonical name and get the same +bound_to+, +sql_at+ and +after+ handling its {OPERATIONS} entry asks
    # for. Only the pipeline name is shared: the driver is still called under the original spelling.
    #
    # For example, the +sync_+ and +async_+ forms of an operation are two different calls, the first
    # blocking in libpq and the second sending and then waiting on the socket from Ruby, where the
    # wait can be interrupted. Which of the two a bare +exec+ means is itself settable, through
    # +PG::Connection.async_api=+.
    #
    # A +sync_+ or +async_+ spelling that is missing here is still recognized, by {#operation_for}
    # removing the prefix. The current spellings are written out here anyway, so that the list can
    # be checked against the gem.
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

    # A statement can also be prepared by sending a +PREPARE+ rather than by calling pg's own
    # +prepare+, and the +exec_prepared+ that runs it looks no different either way. The two are read
    # here so that a statement prepared the first way is remembered like one prepared the second, and
    # a plugin that has to inspect the statement a call runs still has it to look at.
    #
    # The name is an identifier, so an unquoted one is folded to lower case. The parameter types in
    # front of +AS+ are optional. What follows +AS+ is the statement, to the end of the string, which
    # a +PREPARE+ shares with nothing else unless the caller sent more than one statement at once.
    #
    # Read with a pattern rather than a parse because this sits on the path of every statement the
    # connection sends, and the two pieces wanted here are a name and everything after +AS+.
    # +Utils::Parser::PgStatementAnalyzer+ reads the same construct properly, from the parse tree, for
    # the plugin that has to know what the carried statement writes.
    STATEMENT_NAME = /"(?:[^"]|"")+"|\w+/
    SQL_PREPARE    = /\A\s*PREPARE\s+(#{STATEMENT_NAME})\s*(?:\([^)]*\)\s*)?AS\s+(.+)\z/im
    # +DEALLOCATE [PREPARE] { name | ALL }+ un-prepares what a +PREPARE+ prepared, which is what
    # +close_prepared+ does to a statement prepared through the driver.
    SQL_DEALLOCATE = /\A\s*DEALLOCATE\s+(?:PREPARE\s+)?(#{STATEMENT_NAME})\s*;?\s*\z/im

    # Explicitly define critical methods (bypass method_missing to avoid method_missing overhead).

    def exec(sql, *params)
      execute_operation(:exec, [sql, *params])
    end

    # pg spells this operation +exec+, +query+, +async_exec+ and +async_query+, all of which run the
    # same libpq call. +query+ is defined here rather than left to method_missing because it is the
    # spelling applications use most after +exec+, and it enters the pipeline as +connection.exec+,
    # since that is the libpq operation being performed.
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

    # Resets the connection through the pipeline and returns this wrapper, so the reset connection stays
    # usable through it. The driver's own reset tears down and re-establishes the underlying socket, which
    # clears any server-side session state, so the tracked session state is reset to match.
    def reset
      execute_operation(:reset)
      self
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

    # The connection and the statement are held for as long as the block runs and let go afterward even
    # if the block raises. The rows the block feeds or reads belong to that statement, and it is the only
    # place they are named, so it is what the calls inside the block publish.
    def copy_data(sql, coder = nil, &)
      @copy_conn = current_conn
      @copy_sql = sql
      execute_operation(:copy_data, [sql, coder], &)
    ensure
      @copy_conn = nil
      @copy_sql = nil
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

    # A concise representation that never exposes the connection config (which carries
    # credentials) or the cached SQL text this instance holds. Defined so a default
    # dump - via logging, interpolation, `pp`, or a backtrace - cannot leak either.
    def inspect
      format('#<%<class>s:0x%<addr>016x>', class: self.class.name, addr: object_id << 1)
    end
    alias to_s inspect

    def pretty_print(pp)
      pp.text(inspect)
    end

    private

    # Runs one canonical operation through the pipeline, passing the operation's `bound_to` connection and
    # the SQL it carries, and performing any `after` steps as necessary. The SQL is read before the call is
    # made, since an `after` step may be what forgets it, and it is handed to the result as well, so that a
    # plugin which has to inspect the statement still sees it when the rows are read.
    def execute_operation(operation, args = [], kwargs = {}, spelling: operation, &)
      spec = OPERATIONS[operation] || { method: "connection.#{operation}" }
      conn = current_conn
      # Guard against a missing connection. Fail loudly instead.
      raise NoMethodError, 'Connection not initialized' if conn.nil?

      # Only forward keyword arguments when there are any.
      sql = sql_for(spec, args)
      result =
        if kwargs.empty?
          pm.execute(
            spec[:method], conn,
            ->(*a, &b) { current_conn.public_send(spelling, *a, &b) },
            *args, bounded_conn: bounded_conn_for(spec[:bound_to], args), sql: sql, &
          )
        else
          pm.execute(
            spec[:method], conn,
            ->(*a, **opts, &b) { current_conn.public_send(spelling, *a, **opts, &b) },
            *args, **kwargs, bounded_conn: bounded_conn_for(spec[:bound_to], args), sql: sql, &
          )
        end
      Array(spec[:after]).each { |hook| send(hook, args, result, sql) }
      wrap_pg_result(result, sql)
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

    # @return [String, nil] the SQL the operation carries, taken from its arguments when it names a
    #   statement of its own and from whatever it is bound to when it does not
    def sql_for(spec, args)
      return args[spec[:sql_at]] if spec[:sql_at]

      case spec[:bound_to]
      when :prepared then @prepared_sql[args.first]
      when :async then @async_sql
      when :copy then @copy_sql
      end
    end

    # -- What an operation leaves behind, named by the +after+ entries of {OPERATIONS} --

    # A reset re-establishes the underlying socket, dropping any server-side session state (open
    # transaction, autocommit setting), so the tracked state is reset to match the fresh connection.
    def reset_session_state(_args, _result, _sql)
      @service_container.session_state_service.reset
    end

    def remember_prepared(args, _result, sql)
      @prepared_on[args.first] = current_conn
      @prepared_sql[args.first] = sql
    end

    def forget_prepared(args, _result, _sql)
      @prepared_on.delete(args.first)
      @prepared_sql.delete(args.first)
    end

    # A +PREPARE+ or +DEALLOCATE+ that was sent as a statement, treated as the +prepare+ or the
    # +close_prepared+ it amounts to. Anything else that was sent is left alone.
    def remember_sql_prepared(_args, _result, sql)
      return unless sql.is_a?(String)

      if (prepared = SQL_PREPARE.match(sql))
        remember_prepared([statement_name_of(prepared[1])], nil, prepared[2].strip)
      elsif (deallocated = SQL_DEALLOCATE.match(sql))
        forget_sql_prepared(deallocated[1])
      end
    end

    # +DEALLOCATE ALL+ un-prepares every statement of the session, which +ALL+ in quotes does not: that
    # names one statement actually called +ALL+.
    def forget_sql_prepared(name_token)
      if !name_token.start_with?('"') && name_token.casecmp('ALL').zero?
        @prepared_on.clear
        @prepared_sql.clear
      else
        forget_prepared([statement_name_of(name_token)], nil, nil)
      end
    end

    # The name a statement prepared by a +PREPARE+ ends up with. Being an identifier, it is folded to
    # lower case unless it was quoted, and that folded name is the one the +exec_prepared+ which runs
    # it has to give as well, so it is the one to remember it under.
    def statement_name_of(name_token)
      return name_token.downcase unless name_token.start_with?('"')

      name_token[1..-2].gsub('""', '"')
    end

    def remember_async(_args, _result, sql)
      @async_conn = current_conn
      @async_sql = sql
    end

    def forget_async(_args, _result, _sql)
      @async_conn = nil
      @async_sql = nil
    end

    # get_result answers nil once the last result of a pending exchange has been read, and there is
    # nothing left to be bound to.
    def forget_async_when_drained(_args, result, _sql)
      return unless result.nil?

      @async_conn = nil
      @async_sql = nil
    end

    def forget_copy(_args, _result, _sql)
      @copy_conn = nil
      @copy_sql = nil
    end

    def remember_large_object(_args, _result, _sql)
      @lo_conn = current_conn
    end

    def forget_large_object(_args, _result, _sql)
      @lo_conn = nil
    end

    def ensure_pg!
      require 'pg'
    rescue LoadError
      raise LoadError, "WrapperPgConnection requires 'pg'. Add it to your Gemfile: gem 'pg'"
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
      pm.execute(RubyMethod::RESULT_EACH, current_conn, ->(&blk) { @result.each(&blk) },
                 bounded_conn: @connection, sql: @sql, field_names: -> { @result.fields }, &)
    end

    def each_row(&)
      pm.execute(RubyMethod::RESULT_EACH_ROW, current_conn, ->(&blk) { @result.each_row(&blk) },
                 bounded_conn: @connection, sql: @sql, field_names: -> { @result.fields }, &)
    end

    def to_a
      pm.execute(RubyMethod::RESULT_TO_A, current_conn, -> { @result.to_a },
                 bounded_conn: @connection, sql: @sql, field_names: -> { @result.fields })
    end

    def [](index)
      pm.execute(RubyMethod::RESULT_BRACKET, current_conn, ->(*a) { @result[*a] }, index,
                 bounded_conn: @connection, sql: @sql, field_names: -> { @result.fields })
    end

    def values
      pm.execute(RubyMethod::RESULT_VALUES, current_conn, -> { @result.values },
                 bounded_conn: @connection, sql: @sql, field_names: -> { @result.fields })
    end

    def column_values(index)
      pm.execute(RubyMethod::RESULT_COLUMN_VALUES, current_conn, ->(*a) { @result.column_values(*a) }, index,
                 bounded_conn: @connection, sql: @sql, field_names: -> { @result.fields })
    end

    def field_values(field_name)
      pm.execute(RubyMethod::RESULT_FIELD_VALUES, current_conn, ->(*a) { @result.field_values(*a) }, field_name,
                 bounded_conn: @connection, sql: @sql)
    end

    def tuple(index)
      pm.execute(RubyMethod::RESULT_TUPLE, current_conn, ->(*a) { @result.tuple(*a) }, index,
                 bounded_conn: @connection, sql: @sql, field_names: -> { @result.fields })
    end

    def tuple_values(index)
      pm.execute(RubyMethod::RESULT_TUPLE_VALUES, current_conn, ->(*a) { @result.tuple_values(*a) }, index,
                 bounded_conn: @connection, sql: @sql, field_names: -> { @result.fields })
    end

    def getvalue(row, column)
      pm.execute(RubyMethod::RESULT_GETVALUE, current_conn, ->(*a) { @result.getvalue(*a) }, row, column,
                 bounded_conn: @connection, sql: @sql, field_names: -> { @result.fields })
    end

    # The single-row-mode iterators, which read rows off the wire one at a time rather than from a
    # buffered result; they hand out the same row shapes as +each+, +each_row+ and +tuple+.
    def stream_each(&)
      pm.execute(RubyMethod::RESULT_STREAM_EACH, current_conn, ->(&blk) { @result.stream_each(&blk) },
                 bounded_conn: @connection, sql: @sql, field_names: -> { @result.fields }, &)
    end

    def stream_each_row(&)
      pm.execute(RubyMethod::RESULT_STREAM_EACH_ROW, current_conn, ->(&blk) { @result.stream_each_row(&blk) },
                 bounded_conn: @connection, sql: @sql, field_names: -> { @result.fields }, &)
    end

    def stream_each_tuple(&)
      pm.execute(RubyMethod::RESULT_STREAM_EACH_TUPLE, current_conn, ->(&blk) { @result.stream_each_tuple(&blk) },
                 bounded_conn: @connection, sql: @sql, field_names: -> { @result.fields }, &)
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

    def inspect
      format('#<%<class>s:0x%<addr>016x>', class: self.class.name, addr: object_id << 1)
    end
    alias to_s inspect

    def pretty_print(pp)
      pp.text(inspect)
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
