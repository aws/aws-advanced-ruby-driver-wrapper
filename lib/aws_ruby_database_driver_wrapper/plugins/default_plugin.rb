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

require 'resolv'
require 'set'
require_relative '../errors'
require_relative '../host/host_info'
require_relative '../host/host_availability'
require_relative '../property_definition'
require_relative '../utils/rds_utils'
require_relative '../utils/sql_method_analyzer'

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
        dialect = @service_container.dialect_service.driver_dialect
        conn = attempt_connect(dialect, host_info, props)

        @service_container.host_service&.set_availability(host_info, Host::HostAvailability::AVAILABLE)

        if is_initial_connection
          begin
            @service_container.dialect_service.update_dialect(conn)
          rescue NotImplementedError
            # update_dialect not yet implemented; skip
          end

          connection_service = @service_container.connection_service
          if connection_service.pg? && connection_service.multi_host_url?
            connection_service.initial_host_info = Host::HostInfo.new(
              host: conn.host,
              port: conn.port.to_i
            )
          end
        end

        conn
      end

      def execute(_target_obj, target_method_name, target_callable, *args, **options, &block)
        session = @service_container.session_state_service
        autocommit_before = session&.autocommit?

        result = target_callable.call(*args, **options, &block)

        update_transaction_state(session, target_method_name, args, autocommit_before) if session

        result
      end

      private

      def attempt_connect(dialect, host_info, props)
        dialect.connect(host_info, props)
      rescue StandardError => e
        raise unless dns_resolution_error?(e)
        raise unless green_node_replacement_enabled?
        raise unless Utils::RdsUtils.rds_dns?(host_info.host) && Utils::RdsUtils.green_instance?(host_info.host)
        raise if dns_resolves?(host_info.host)

        fixed_host = Utils::RdsUtils.remove_green_instance_prefix(host_info.host)
        fixed_host_info = host_info.dup.tap { |h| h.host = fixed_host }
        dialect.connect(fixed_host_info, props)
      end

      def update_transaction_state(session, method_name, args, autocommit_before)
        if Utils::SqlMethodAnalyzer.opens_transaction?(method_name, args, autocommit: session.autocommit?)
          session.in_transaction = true
        elsif Utils::SqlMethodAnalyzer.closes_transaction?(method_name, args) ||
              (!autocommit_before && Utils::SqlMethodAnalyzer.sets_autocommit?(method_name, args) &&
               Utils::SqlMethodAnalyzer.autocommit_value(args) == true)
          session.in_transaction = false
        end

        return unless Utils::SqlMethodAnalyzer.sets_autocommit?(method_name, args)

        val = Utils::SqlMethodAnalyzer.autocommit_value(args)
        session.autocommit = val unless val.nil?
      end

      def green_node_replacement_enabled?
        PropertyDefinition::ENABLE_GREEN_NODE_REPLACEMENT.get_bool(@service_container.connection_service.wrapper_props)
      end

      def dns_resolution_error?(error)
        return true if error.is_a?(SocketError)

        error.message.to_s.include?('could not translate host name') ||
          error.message.to_s.include?('Name or service not known')
      end

      def dns_resolves?(host)
        Resolv.getaddress(host)
        true
      rescue Resolv::ResolvError
        false
      end
    end
  end
end
