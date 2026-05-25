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
      @service_container.plugin_manager.execute(
        current_conn, @connection, @connection, RubyMethod::CONNECTION_EXEC,
        ->(*args) { @connection.exec(*args) }, sql, *params
      )
    end

    def exec_params(sql, params, result_format = 0, type_map = nil)
      @service_container.plugin_manager.execute(
        current_conn, @connection, @connection, RubyMethod::CONNECTION_EXEC_PARAMS,
        ->(*args) { @connection.exec_params(*args) },
        sql, params, result_format, type_map
      )
    end

    def prepare(stmt_name, sql, param_types = nil)
      @service_container.plugin_manager.execute(
        current_conn, @connection, @connection, RubyMethod::CONNECTION_PREPARE,
        ->(*args) { @connection.prepare(*args) },
        stmt_name, sql, param_types
      )
    end

    def exec_prepared(stmt_name, params = [], result_format = 0, type_map = nil)
      @service_container.plugin_manager.execute(
        current_conn, @connection, @connection, RubyMethod::CONNECTION_EXEC_PREPARED,
        ->(*args) { @connection.exec_prepared(*args) },
        stmt_name, params, result_format, type_map
      )
    end

    def transaction(&block)
      @service_container.plugin_manager.execute(
        current_conn, @connection, @connection, RubyMethod::CONNECTION_TRANSACTION,
        ->(&b) { @connection.transaction(&b) },
        &block
      )
    end

    def async_exec(sql, *params)
      @service_container.plugin_manager.execute(
        current_conn, @connection, @connection, RubyMethod::CONNECTION_ASYNC_EXEC,
        ->(*args) { @connection.async_exec(*args) },
        sql, *params
      )
    end

    # Catch methods not explicitly defined
    def method_missing(method_name, *args, **options, &block)
      raise NoMethodError, 'Connection not initialized' if @connection.nil?

      raise NoMethodError, "undefined method `#{method_name}' for #{self.class}" unless @connection.respond_to?(method_name)

      @service_container.plugin_manager.execute(
        current_conn, @connection, @connection, "connection.#{method_name}",
        ->(*a, **opts, &b) { @connection.send(method_name, *a, **opts, &b) },
        *args, **options, &block
      )
    end

    def respond_to_missing?(method, include_private = false)
      @connection.respond_to?(method, include_private) || super
    end

    private

    def current_conn
      @service_container.connection_service.current_connection
    end
  end
end
