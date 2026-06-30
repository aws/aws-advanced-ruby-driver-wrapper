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
  class Mysql2WrapperClient
    def self.new(**)
      instance = allocate
      instance.send(:initialize, **)
      instance
    end

    def initialize(**)
      config = Utils::ConnectionConfigParser.parse(:mysql2, **)
      @service_container = Services::ServiceUtility.create_standard_container(config)
      @async_conn = nil
      conn_service = @service_container.connection_service
      @service_container.plugin_manager.connect(conn_service.initial_host_info, conn_service.driver_props, true)
    end

    # Explicitly define critical methods (bypass method_missing to avoid method_missing overhead)

    def query(sql, options = {})
      result = pm.execute(RubyMethod::CONNECTION_QUERY, current_conn, ->(*a) { current_conn.query(*a) }, sql, options)
      wrap_mysql_result(result)
    end

    def prepare(sql)
      mysql_stmt = pm.execute(RubyMethod::CONNECTION_PREPARE, current_conn, ->(*a) { current_conn.prepare(*a) }, sql)
      Mysql2WrapperStatement.new(@service_container, current_conn, mysql_stmt)
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

    # -- Async writer (store @async_conn) --

    def query_async(sql, options = {})
      result = pm.execute(RubyMethod::CONNECTION_QUERY_ASYNC, current_conn, ->(*a) { current_conn.query_async(*a) }, sql, options)
      @async_conn = current_conn
      wrap_mysql_result(result)
    end

    # -- Async readers (check bounded to @async_conn) --

    def store_result
      result = pm.execute(RubyMethod::CONNECTION_STORE_RESULT, current_conn, -> { current_conn.store_result }, bounded_conn: @async_conn)
      @async_conn = nil
      wrap_mysql_result(result)
    end

    def more_results
      pm.execute(RubyMethod::CONNECTION_MORE_RESULTS, current_conn, -> { current_conn.more_results }, bounded_conn: @async_conn)
    end

    def next_result
      pm.execute(RubyMethod::CONNECTION_NEXT_RESULT, current_conn, -> { current_conn.next_result }, bounded_conn: @async_conn)
    end

    # -- method_missing: non-network bypasses pipeline --

    def method_missing(method_name, ...)
      conn = current_conn
      raise NoMethodError, 'Connection not initialized' if conn.nil?
      raise NoMethodError, "undefined method `#{method_name}' for #{self.class}" unless conn.respond_to?(method_name)

      method_key = "connection.#{method_name}"
      return conn.send(method_name, ...) unless network_bound_methods.include?(method_key)

      result = pm.execute(method_key, conn, ->(*a, **opts, &b) { current_conn.send(method_name, *a, **opts, &b) }, ...)
      wrap_mysql_result(result)
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

    def wrap_mysql_result(result)
      return result unless result.is_a?(Mysql2::Result)

      Mysql2WrapperResult.new(result, @service_container, current_conn)
    end
  end

  class Mysql2WrapperStatement
    def initialize(service_container, connection, mysql_stmt)
      @service_container = service_container
      @connection = connection
      @mysql_stmt = mysql_stmt
    end

    def execute(*params, **)
      result = pm.execute(
        RubyMethod::STATEMENT_EXECUTE, current_conn,
        ->(*p, **o) { @mysql_stmt.execute(*p, **o) },
        *params, bounded_conn: @connection, **
      )
      return result unless result.is_a?(Mysql2::Result)

      Mysql2WrapperResult.new(result, @service_container, @connection)
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

    def initialize(result, service_container, connection)
      @result = result
      @service_container = service_container
      @connection = connection
    end

    def each(*args, &block)
      pm.execute(RubyMethod::RESULT_EACH, current_conn, ->(&blk) { @result.each(*args, &blk) }, bounded_conn: @connection, &block)
    end

    def to_a
      pm.execute(RubyMethod::RESULT_TO_A, current_conn, -> { @result.to_a }, bounded_conn: @connection)
    end

    def [](index)
      pm.execute(RubyMethod::RESULT_BRACKET, current_conn, ->(*a) { @result[*a] }, index, bounded_conn: @connection)
    end

    # Delegate non-network methods directly
    def fields
      @result.fields
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

    def free
      @result.free
    end

    def server_flags
      @result.server_flags
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
