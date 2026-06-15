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
    def self.new(**options)
      instance = allocate
      instance.send(:initialize, **options)
      instance
    end

    def initialize(**options)
      config = Utils::ConnectionConfigParser.parse(:mysql2, **options)
      @service_container = Services::ServiceUtility.create_standard_container(config)
      conn_service = @service_container.connection_service
      @connection =
        @service_container.plugin_manager.connect(conn_service.initial_host_info, conn_service.driver_props, true)
    end

    # Explicitly define critical methods (bypass method_missing to avoid method_missing overhead)

    def query(sql, options = {})
      result = @service_container.plugin_manager.execute(
        current_conn, @connection, @connection, RubyMethod::CONNECTION_QUERY,
        ->(*args) { @connection.query(*args) }, sql, options
      )
      return result if result.nil?

      Mysql2WrapperResult.new(result, @service_container, @connection)
    end

    def prepare(sql)
      mysql_stmt = @service_container.plugin_manager.execute(
        current_conn, @connection, @connection, RubyMethod::CONNECTION_PREPARE,
        ->(*args) { @connection.prepare(*args) }, sql
      )
      Mysql2WrapperStatement.new(@service_container, @connection, mysql_stmt)
    end

    def escape(string)
      @service_container.plugin_manager.execute(
        current_conn, @connection, @connection, RubyMethod::CONNECTION_ESCAPE,
        ->(*args) { @connection.escape(*args) }, string
      )
    end

    def ping
      @service_container.plugin_manager.execute(
        current_conn, @connection, @connection, RubyMethod::CONNECTION_PING,
        -> { @connection.ping }
      )
    end

    def close
      @service_container.plugin_manager.execute(
        current_conn, @connection, @connection, RubyMethod::CONNECTION_CLOSE,
        -> { @connection.close }
      )
    end

    def query_async(sql, options = {})
      result = @service_container.plugin_manager.execute(
        current_conn, @connection, @connection, RubyMethod::CONNECTION_QUERY_ASYNC,
        ->(*args) { @connection.query_async(*args) },
        sql, options
      )
      return result if result.nil?

      Mysql2WrapperResult.new(result, @service_container, @connection)
    end

    # Catch methods not explicitly defined
    def method_missing(method_name, *args, **options, &block)
      raise NoMethodError, 'Connection not initialized' if @connection.nil?

      raise NoMethodError, "undefined method `#{method_name}' for #{self.class}" unless @connection.respond_to?(method_name)

      result = @service_container.plugin_manager.execute(
        current_conn, @connection, @connection, "connection.#{method_name}",
        ->(*a, **opts, &b) { @connection.send(method_name, *a, **opts, &b) },
        *args, **options, &block
      )
      return result if result.nil? || !result.is_a?(Mysql2::Result)

      Mysql2WrapperResult.new(result, @service_container, @connection)
    end

    def respond_to_missing?(method, include_private = false)
      @connection.respond_to?(method, include_private) || super
    end

    private

    def current_conn
      @service_container.connection_service.current_connection
    end
  end

  class Mysql2WrapperStatement
    def initialize(service_container, connection, mysql_stmt)
      @service_container = service_container
      @connection = connection
      @mysql_stmt = mysql_stmt
    end

    def execute(*params, **options)
      result = @service_container.plugin_manager.execute(
        current_conn, @connection, @mysql_stmt, RubyMethod::STATEMENT_EXECUTE,
        ->(*params, **options) { @mysql_stmt.execute(*params, **options) },
        *params, **options
      )
      return result if result.nil?

      Mysql2WrapperResult.new(result, @service_container, @connection)
    end

    def close
      @service_container.plugin_manager.execute(
        current_conn, @connection, @mysql_stmt, RubyMethod::STATEMENT_CLOSE, -> { @mysql_stmt.close }
      )
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
  end

  class Mysql2WrapperResult
    include Enumerable

    def initialize(result, service_container, connection)
      @result = result
      @service_container = service_container
      @connection = connection
    end

    def each(*args, &block)
      @service_container.plugin_manager.execute(
        @service_container.connection_service.current_connection, @connection, @connection, RubyMethod::RESULT_EACH,
        ->(&blk) { @result.each(*args, &blk) },
        &block
      )
    end

    def to_a
      @service_container.plugin_manager.execute(
        @service_container.connection_service.current_connection, @connection, @connection, RubyMethod::RESULT_TO_A,
        -> { @result.to_a }
      )
    end

    def [](index)
      @service_container.plugin_manager.execute(
        @service_container.connection_service.current_connection, @connection, @connection, RubyMethod::RESULT_BRACKET,
        ->(*args) { @result[*args] }, index
      )
    end

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
  end
end
