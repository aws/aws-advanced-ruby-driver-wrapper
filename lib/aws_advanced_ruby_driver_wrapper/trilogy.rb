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

require_relative '../aws_advanced_ruby_driver_wrapper'
require_relative 'utils/connection_config_parser'
require_relative 'utils/sql_encoding'
require_relative 'services/service_utility'
require_relative 'ruby_method'
require_relative 'errors'

module AwsAdvancedRubyDriverWrapper
  # A drop-in for a Trilogy connection. Trilogy has no prepared statements and no asynchronous or
  # streaming reads, and it reads a result off the wire in full before returning it, so the only calls
  # that reach the server are made on the connection itself, and results are handed back unwrapped.
  class WrapperTrilogyClient
    # Trilogy.new takes its options as a single hash, so this does too, and keyword arguments as well.
    def self.new(options = {}, **)
      instance = allocate
      instance.send(:initialize, options, **)
      instance
    end

    def initialize(options = {}, **)
      ensure_trilogy!
      config = Utils::ConnectionConfigParser.parse(:trilogy, **options, **)
      @service_container = Services::ServiceUtility.create_standard_container(config)
      @service_container.host_service.refresh_host_list
      @query_conn = nil
      @last_sql = nil
      conn_service = @service_container.connection_service
      @service_container.plugin_manager.connect(conn_service.initial_host_info, conn_service.driver_props, true)
    end

    # Explicitly define critical methods (bypass method_missing to avoid method_missing overhead)

    # The connection a statement was sent on is remembered, and so is its SQL, because the further
    # result sets a statement leaves are read by calls of their own (next_result, abandon_results!),
    # which carry neither and can only be made on that connection.
    #
    # What is remembered is the copy of the SQL that plugins inspect. The driver is sent the SQL as
    # the application wrote it.
    def query(sql)
      inspected = Utils::SqlEncoding.inspectable(sql)
      result = pm.execute(RubyMethod::CONNECTION_QUERY, current_conn, ->(*a) { current_conn.query(*a) }, sql,
                          sql: inspected)
      @query_conn = current_conn
      @last_sql = inspected
      result
    end

    def ping
      pm.execute(RubyMethod::CONNECTION_PING, current_conn, -> { current_conn.ping })
    end

    def close
      pm.execute(RubyMethod::CONNECTION_CLOSE, current_conn, -> { current_conn.close })
    end

    def next_result
      pm.execute(RubyMethod::CONNECTION_NEXT_RESULT, current_conn, -> { current_conn.next_result },
                 bounded_conn: @query_conn, sql: @last_sql)
    end

    # -- method_missing: covers non-network calls and rarely used network calls --

    # The network calls that are rare enough not to be worth a method of their own. They are entered
    # into the pipeline under the name the pipeline knows them by rather than as a bare string, so
    # that the connection each is bound to is checked.
    DYNAMIC_METHODS = {
      abandon_results!: RubyMethod::CONNECTION_ABANDON_RESULTS,
      change_db: RubyMethod::CONNECTION_CHANGE_DB,
      set_server_option: RubyMethod::CONNECTION_SET_SERVER_OPTION
    }.freeze

    # Draining what is left of a statement can only be done on the connection it was sent on.
    BOUNDED_TO_QUERY = Set[:abandon_results!].freeze

    def method_missing(method_name, *, **, &)
      conn = current_conn
      raise NoMethodError, 'Connection not initialized' if conn.nil?
      raise NoMethodError, "undefined method `#{method_name}' for #{self.class}" unless conn.respond_to?(method_name)

      method_key = "connection.#{method_name}"
      return conn.send(method_name, *, **, &) unless network_bound_methods.include?(method_key)

      bounded_conn = BOUNDED_TO_QUERY.include?(method_name) ? @query_conn : nil
      pm.execute(
        DYNAMIC_METHODS[method_name] || method_key, current_conn,
        ->(*a, **opts, &b) { current_conn.send(method_name, *a, **opts, &b) },
        *, **, bounded_conn: bounded_conn, &
      )
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

    def ensure_trilogy!
      require 'trilogy'
    rescue LoadError
      raise LoadError, "WrapperTrilogyClient requires 'trilogy'. Add it to your Gemfile: gem 'trilogy'"
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
  end
end
