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
      def new(*args, **options)
        instance = allocate
        instance.send(:initialize, *args, **options)
        instance
      end

      alias open new
      alias connect new
    end

    def initialize(*args, **options)
      config = Utils::ConnectionConfigParser.parse(:postgresql, *args, **options)
      @service_container = Services::ServiceUtility.create_standard_container(config)
      conn_service = @service_container.connection_service
      @connection =
        @service_container.plugin_manager.connect(conn_service.initial_host_info, conn_service.driver_props, true)
    end

    # Explicitly define critical methods (bypass method_missing to avoid method_missing overhead).

    def exec(sql, *params)
      result = @service_container.plugin_manager.execute(
        current_conn, @connection, @connection, RubyMethod::CONNECTION_EXEC,
        ->(*args) { @connection.exec(*args) }, sql, *params
      )
      return result if result.nil?

      WrapperPgResult.new(result, @service_container, @connection)
    end

    def exec_params(sql, params, result_format = 0, type_map = nil)
      result = @service_container.plugin_manager.execute(
        current_conn, @connection, @connection, RubyMethod::CONNECTION_EXEC_PARAMS,
        ->(*args) { @connection.exec_params(*args) },
        sql, params, result_format, type_map
      )
      return result if result.nil?

      WrapperPgResult.new(result, @service_container, @connection)
    end

    def prepare(stmt_name, sql, param_types = nil)
      @service_container.plugin_manager.execute(
        current_conn, @connection, @connection, RubyMethod::CONNECTION_PREPARE,
        ->(*args) { @connection.prepare(*args) },
        stmt_name, sql, param_types
      )
    end

    def exec_prepared(stmt_name, params = [], result_format = 0, type_map = nil)
      result = @service_container.plugin_manager.execute(
        current_conn, @connection, @connection, RubyMethod::CONNECTION_EXEC_PREPARED,
        ->(*args) { @connection.exec_prepared(*args) },
        stmt_name, params, result_format, type_map
      )
      return result if result.nil?

      WrapperPgResult.new(result, @service_container, @connection)
    end

    def transaction(&block)
      @service_container.plugin_manager.execute(
        current_conn, @connection, @connection, RubyMethod::CONNECTION_TRANSACTION,
        ->(&b) { @connection.transaction(&b) },
        &block
      )
    end

    def async_exec(sql, *params)
      result = @service_container.plugin_manager.execute(
        current_conn, @connection, @connection, RubyMethod::CONNECTION_ASYNC_EXEC,
        ->(*args) { @connection.async_exec(*args) },
        sql, *params
      )
      return result if result.nil?

      WrapperPgResult.new(result, @service_container, @connection)
    end

    def get_result # rubocop:disable Naming/AccessorMethodName
      result = @service_container.plugin_manager_service.execute(
        current_conn, @connection, @connection, RubyMethod::CONNECTION_GET_RESULT,
        -> { @connection.get_result }
      )
      return result if result.nil?

      WrapperPgResult.new(result, @service_container, @connection)
    end

    def get_last_result # rubocop:disable Naming/AccessorMethodName
      result = @service_container.plugin_manager_service.execute(
        current_conn, @connection, @connection, RubyMethod::CONNECTION_GET_LAST_RESULT,
        -> { @connection.get_last_result }
      )
      return result if result.nil?

      WrapperPgResult.new(result, @service_container, @connection)
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
      return result if result.nil? || !result.is_a?(PG::Result)

      WrapperPgResult.new(result, @service_container, @connection)
    end

    def respond_to_missing?(method, include_private = false)
      @connection.respond_to?(method, include_private) || super
    end

    private

    def current_conn
      @service_container.connection_service.current_connection
    end
  end

  class WrapperPgResult
    include Enumerable

    def initialize(result, service_container, connection)
      @result = result
      @service_container = service_container
      @connection = connection
    end

    def each(&block)
      @service_container.plugin_manager_service.execute(
        @service_container.connection_service.current_connection, @connection, @connection, RubyMethod::RESULT_EACH,
        ->(&blk) { @result.each(&blk) },
        &block
      )
    end

    def each_row(&block)
      @service_container.plugin_manager_service.execute(
        @service_container.connection_service.current_connection, @connection, @connection, RubyMethod::RESULT_EACH_ROW,
        ->(&blk) { @result.each_row(&blk) },
        &block
      )
    end

    def to_a
      @service_container.plugin_manager_service.execute(
        @service_container.connection_service.current_connection, @connection, @connection, RubyMethod::RESULT_TO_A,
        -> { @result.to_a }
      )
    end

    def [](index)
      @service_container.plugin_manager_service.execute(
        @service_container.connection_service.current_connection, @connection, @connection, RubyMethod::RESULT_BRACKET,
        ->(*args) { @result[*args] }, index
      )
    end

    def values
      @service_container.plugin_manager_service.execute(
        @service_container.connection_service.current_connection, @connection, @connection, RubyMethod::RESULT_VALUES,
        -> { @result.values }
      )
    end

    def column_values(index)
      @service_container.plugin_manager_service.execute(
        @service_container.connection_service.current_connection, @connection, @connection, RubyMethod::RESULT_COLUMN_VALUES,
        ->(*args) { @result.column_values(*args) }, index
      )
    end

    def field_values(field_name)
      @service_container.plugin_manager_service.execute(
        @service_container.connection_service.current_connection, @connection, @connection, RubyMethod::RESULT_FIELD_VALUES,
        ->(*args) { @result.field_values(*args) }, field_name
      )
    end

    def tuple(index)
      @service_container.plugin_manager_service.execute(
        @service_container.connection_service.current_connection, @connection, @connection, RubyMethod::RESULT_TUPLE,
        ->(*args) { @result.tuple(*args) }, index
      )
    end

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

    def method_missing(method_name, *args, &block)
      @result.send(method_name, *args, &block)
    end

    def respond_to_missing?(method, include_private = false)
      @result.respond_to?(method, include_private) || super
    end
  end
end
