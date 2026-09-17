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
  class WrapperMysql2Client
    def self.new(**)
      instance = allocate
      instance.send(:initialize, **)
      instance
    end

    def initialize(**)
      ensure_mysql2!
      config = Utils::ConnectionConfigParser.parse(:mysql2, **)
      @service_container = Services::ServiceUtility.create_standard_container(config)
      @service_container.host_service.refresh_host_list
      @async_conn = nil
      @async_sql = nil
      @last_sql = nil
      conn_service = @service_container.connection_service
      @service_container.plugin_manager.connect(conn_service.initial_host_info, conn_service.driver_props, true)
    end

    # Explicitly define critical methods (bypass method_missing to avoid method_missing overhead)

    # This is how mysql2 sends a statement asynchronously as well: +query(sql, async: true)+ returns
    # nothing and the result is read afterward by +async_result+. The connection the statement was
    # sent on is remembered for that read, and so is its SQL, since the read is a call of its own and
    # carries neither.
    def query(sql, options = {})
      result = pm.execute(RubyMethod::CONNECTION_QUERY, current_conn, ->(*a) { current_conn.query(*a) }, sql, options, sql: sql)
      @last_sql = sql
      if options[:async]
        @async_conn = current_conn
        @async_sql = sql
      end
      wrap_mysql_result(result, sql)
    end

    def prepare(sql)
      mysql_stmt = pm.execute(RubyMethod::CONNECTION_PREPARE, current_conn, ->(*a) { current_conn.prepare(*a) }, sql, sql: sql)
      Mysql2WrapperStatement.new(@service_container, current_conn, mysql_stmt, sql)
    end

    def escape(string)
      pm.execute(RubyMethod::CONNECTION_ESCAPE, current_conn, ->(*a) { current_conn.escape(*a) }, string)
    end

    def ping
      pm.execute(RubyMethod::CONNECTION_PING, current_conn, -> { current_conn.ping })
    end

    def close
      pm.execute(RubyMethod::CONNECTION_CLOSE, current_conn, -> { current_conn.close })
    end

    # -- Async readers (check bounded to @async_conn) --

    # The result of a statement that was sent with +async: true+. It is read by a call of its own, so
    # it is handed the SQL of the statement it belongs to, and it is refused on any connection other
    # than the one that statement was sent on.
    def async_result
      result = pm.execute(RubyMethod::CONNECTION_ASYNC_RESULT, current_conn, -> { current_conn.async_result },
                          bounded_conn: @async_conn, sql: @async_sql)
      sql = @async_sql
      @async_conn = nil
      @async_sql = nil
      wrap_mysql_result(result, sql)
    end

    def store_result
      result = pm.execute(RubyMethod::CONNECTION_STORE_RESULT, current_conn, -> { current_conn.store_result },
                          bounded_conn: @async_conn, sql: @async_sql)
      sql = @async_sql
      @async_conn = nil
      @async_sql = nil
      wrap_mysql_result(result, sql)
    end

    def more_results?
      pm.execute(RubyMethod::CONNECTION_MORE_RESULTS, current_conn, -> { current_conn.more_results? }, bounded_conn: @async_conn)
    end

    # A statement that leaves more than one result set is read by moving to each in turn and storing
    # it. Storing a result forgets the connection the statement was sent on and the SQL that was sent
    # on it, and every one of those results belongs to that statement, so both are put back for the
    # read that follows and dropped once there is nothing left to read.
    def next_result
      result = pm.execute(RubyMethod::CONNECTION_NEXT_RESULT, current_conn, -> { current_conn.next_result },
                          bounded_conn: @async_conn)
      if result
        @async_conn = current_conn
        @async_sql = @last_sql
      else
        @async_conn = nil
        @async_sql = nil
      end
      result
    end

    # -- method_missing: covers non-network calls and rarely used network calls --

    # The network calls that are rare enough not to be worth a method of their own. They are entered
    # into the pipeline under the name the pipeline knows them by rather than as a bare string, so
    # that the connection each is bound to is checked. mysql2 gives none of its calls a second
    # spelling, so unlike pg there is nothing here to translate.
    DYNAMIC_METHODS = {
      abandon_results!: RubyMethod::CONNECTION_ABANDON_RESULTS,
      select_db: RubyMethod::CONNECTION_SELECT_DB,
      set_server_option: RubyMethod::CONNECTION_SET_SERVER_OPTION
    }.freeze

    # Draining what is left of a statement can only be done on the connection it was sent on.
    BOUNDED_TO_ASYNC = Set[:abandon_results!].freeze

    def method_missing(method_name, *args, **kwargs, &)
      conn = current_conn
      raise NoMethodError, 'Connection not initialized' if conn.nil?
      raise NoMethodError, "undefined method `#{method_name}' for #{self.class}" unless conn.respond_to?(method_name)

      method_key = "connection.#{method_name}"
      return conn.send(method_name, *args, **kwargs, &) unless network_bound_methods.include?(method_key)

      execute_dynamic(method_name, method_key, args, kwargs, &)
    end

    def respond_to_missing?(method, include_private = false)
      current_conn.respond_to?(method, include_private) || super
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

    # Runs a call that reached method_missing through the pipeline, telling the plugins the connection
    # it is bound to, which is known here rather than from the arguments of the call.
    def execute_dynamic(method_name, method_key, args, kwargs, &)
      bounded_conn = BOUNDED_TO_ASYNC.include?(method_name) ? @async_conn : nil
      result = pm.execute(
        DYNAMIC_METHODS[method_name] || method_key, current_conn,
        ->(*a, **opts, &b) { current_conn.send(method_name, *a, **opts, &b) },
        *args, **kwargs, bounded_conn: bounded_conn, &
      )
      if method_name == :abandon_results!
        @async_conn = nil
        @async_sql = nil
      end
      wrap_mysql_result(result)
    end

    def ensure_mysql2!
      require 'mysql2'
    rescue LoadError
      raise LoadError, "WrapperMysql2Client requires 'mysql2'. Add it to your Gemfile: gem 'mysql2'"
    end

    def current_conn
      @service_container.connection_service.current_connection
    end

    def pm
      @service_container.plugin_manager
    end

    def network_bound_methods
      @network_bound_methods ||= @service_container.dialect_service.driver_dialect.network_bound_methods
    end

    def wrap_mysql_result(result, sql = nil)
      return result unless result.is_a?(Mysql2::Result)

      Mysql2WrapperResult.new(result, @service_container, current_conn, sql)
    end
  end

  class Mysql2WrapperStatement
    # @param sql [String, nil] the SQL the statement was prepared with, kept so that plugins
    #   which inspect statements still see it when the statement is executed
    def initialize(service_container, connection, mysql_stmt, sql = nil)
      @service_container = service_container
      @connection = connection
      @mysql_stmt = mysql_stmt
      @sql = sql
    end

    def execute(*params, **)
      result = pm.execute(
        RubyMethod::STATEMENT_EXECUTE, current_conn,
        ->(*p, **o) { @mysql_stmt.execute(*p, **o) },
        *params, bounded_conn: @connection, sql: @sql, **
      )
      return result unless result.is_a?(Mysql2::Result)

      # The statement is handed to the result so it can read column names from the statement's
      # metadata rather than from Mysql2::Result#fields, which dereferences the result's field
      # pointer and segfaults on a prepared statement that returned no rows.
      Mysql2WrapperResult.new(result, @service_container, @connection, @sql, @mysql_stmt)
    end

    def close
      pm.execute(RubyMethod::STATEMENT_CLOSE, current_conn, -> { @mysql_stmt.close })
    end

    # Delegate non-network methods directly
    def fields
      @mysql_stmt.fields
    end

    def field_count
      @mysql_stmt.field_count
    end

    def param_count
      @mysql_stmt.param_count
    end

    def affected_rows
      @mysql_stmt.affected_rows
    end

    def last_id
      @mysql_stmt.last_id
    end

    def closed?
      @mysql_stmt.closed?
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

  class Mysql2WrapperResult
    include Enumerable

    # @param sql [String, nil] the SQL that produced the result, kept so that plugins which
    #   inspect statements still see it when the rows are read
    # @param statement [Mysql2::Statement, nil] the prepared statement the result came from, if any,
    #   used as a safe source of column names (see {#result_field_names})
    def initialize(result, service_container, connection, sql = nil, statement = nil)
      @result = result
      @service_container = service_container
      @connection = connection
      @sql = sql
      @statement = statement
    end

    def each(*args, &block)
      pm.execute(RubyMethod::RESULT_EACH, current_conn, ->(&blk) { @result.each(*args, &blk) },
                 bounded_conn: @connection, sql: @sql, field_names: -> { result_field_names }, &block)
    end

    def to_a
      pm.execute(RubyMethod::RESULT_TO_A, current_conn, -> { @result.to_a },
                 bounded_conn: @connection, sql: @sql, field_names: -> { result_field_names })
    end

    def [](index)
      pm.execute(RubyMethod::RESULT_BRACKET, current_conn, ->(*a) { @result[*a] }, index,
                 bounded_conn: @connection, sql: @sql, field_names: -> { result_field_names })
    end

    # A buffered result is already in client memory, so letting it go is local. An unbuffered one,
    # from +query(sql, stream: true)+, still has whatever was not read on the wire, and libmysql has
    # to drain it before it can free the result. That makes this a call to the server, on the
    # connection the statement was sent on, so it should go through the pipeline.
    def free
      pm.execute(RubyMethod::RESULT_FREE, current_conn, -> { @result.free }, bounded_conn: @connection, sql: @sql)
    end

    # Delegate non-network methods directly
    def fields
      result_field_names
    end

    def field_types
      @result.field_types
    end

    def count
      @result.count
    end

    def size
      @result.size
    end

    def server_flags
      @result.server_flags
    end

    def inspect
      format('#<%<class>s:0x%<addr>016x>', class: self.class.name, addr: object_id << 1)
    end
    alias to_s inspect

    def pretty_print(pp)
      pp.text(inspect)
    end

    private

    # The result's column names. For a prepared-statement result these are read from the statement's
    # own metadata (mysql_stmt_result_metadata), which is populated safely whether or not any rows
    # came back; Mysql2::Result#fields dereferences the result's field pointer, which mysql2 leaves
    # NULL for a prepared statement that returned no rows, and reading it segfaults. Results from
    # +query+ carry no statement, and Mysql2::Result#fields is safe for those.
    def result_field_names
      (@statement || @result).fields
    end

    def current_conn
      @service_container.connection_service.current_connection
    end

    def pm
      @service_container.plugin_manager
    end
  end
end
