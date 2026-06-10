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

require 'set'
require_relative '../errors'
require_relative '../host/host_info'
require_relative '../host/host_availability'

module AwsRubyDatabaseDriverWrapper
  module Plugins
    class DefaultPlugin
      SUBSCRIBED_METHODS = Set['*'].freeze

      def initialize(service_container, **options)
        @service_container = service_container
        @options = options
      end

      def subscribed_methods
        SUBSCRIBED_METHODS
      end

      def connect(host_info, props, is_initial_connection, _pipeline_callable)
        connection_service = @service_container.connection_service
        driver_dialect = @service_container.dialect_service.driver_dialect

        conn = if is_initial_connection && connection_service.multi_host_url?
                 config = connection_service.config
                 multi_host_info = Host::HostInfo.new(
                   host: config.original_host,
                   port: config.original_port
                 )
                 multi_host_props = (props || {}).reject { |k, _| %i[host port].include?(k.to_sym) }
                 driver_dialect.connect(multi_host_info, multi_host_props)
               else
                 driver_dialect.connect(host_info, props)
               end

        @service_container.host_service.set_availability(host_info, Host::HostAvailability::AVAILABLE)
        connection_service.update_current_connection(conn, host_info)

        if is_initial_connection
          @service_container.dialect_service.update_dialect(conn)

          if connection_service.pg? && connection_service.multi_host_url?
            connection_service.config.initial_host_info = Host::HostInfo.new(
              host: conn.host,
              port: conn.port.to_i
            )
          end
        end

        conn
      end

      def internal_connect(host_info, props, _, _is_initial_connection, _pipeline_callable)
        driver_dialect = @service_container.dialect_service.driver_dialect
        driver_dialect.connect(host_info, props)
      end

      def execute(_target_obj, target_method_name, target_callable, *args, **options, &block)
        session = @service_container.session_state_service
        autocommit_before = session&.autocommit?

        result = target_callable.call(*args, **options, &block)

        session&.update_transaction_state(target_method_name, args, autocommit_before)

        result
      end
    end
  end
end
