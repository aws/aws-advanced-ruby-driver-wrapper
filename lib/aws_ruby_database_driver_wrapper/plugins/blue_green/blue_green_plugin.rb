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

require 'concurrent'
require_relative '../../logging'
require_relative '../../ruby_method'
require_relative '../../property_definition'
require_relative '../../utils/rds_utils'
require_relative 'phase'
require_relative 'role'
require_relative 'status'
require_relative 'status_provider'

module AwsRubyDatabaseDriverWrapper
  module Plugins
    module BlueGreen
      class BlueGreenPlugin
        include Logging

        BLUE_GREEN_NAME = :blue_green

        # When present in wrapper_props, internal_connect calls bypass BG routing.
        # Used by BG monitoring connections to avoid being intercepted by their own plugin.
        BG_SKIP_ROUTING_KEY = :'bg.skip_routing'

        CLOSING_METHODS = Set[
          RubyMethod::CONNECTION_CLOSE.name,
          RubyMethod::STATEMENT_CLOSE.name
        ].freeze

        PROVIDERS = Concurrent::Map.new

        def initialize(service_container, props = ::Concurrent::Map.new)
          @service_container = service_container
          @wrapper_props = props
          @bgd_id = PropertyDefinition::BGD_ID.get(props).to_s.strip.downcase
          @bg_status = nil
          @cluster_id = nil
          @start_time_ns = Concurrent::AtomicReference.new(0)
          @end_time_ns = Concurrent::AtomicReference.new(0)

          service_container.storage_service.register(BLUE_GREEN_NAME, ttl: 3600)

          network_methods = service_container.dialect_service.driver_dialect.network_bound_methods
          @subscribed_methods = (Set['connect', 'internal_connect'] | network_methods).freeze
        end

        attr_reader :subscribed_methods

        def connect(host_info, driver_props, is_initial_connection, pipeline_callable)
          route_connect(host_info, driver_props, is_initial_connection, pipeline_callable)
        end

        def internal_connect(host_info, driver_props, wrapper_props, is_initial_connection, pipeline_callable)
          # BG monitoring connections set BG_SKIP_ROUTING_KEY to bypass routing.
          return pipeline_callable.call if wrapper_props[BG_SKIP_ROUTING_KEY]

          route_connect(host_info, driver_props, is_initial_connection, pipeline_callable)
        end

        def execute(method_name, pipeline_callable, *_, **, &)
          reset_routing_time_ns

          begin
            init_provider

            return pipeline_callable.call if CLOSING_METHODS.include?(method_name)

            @bg_status = storage_service.get(BLUE_GREEN_NAME, @bgd_id)
            return pipeline_callable.call if @bg_status.nil?

            current_host = @service_container.connection_service.current_host_info
            host_role = @bg_status.role(current_host)
            return pipeline_callable.call if host_role.nil?

            routing = @bg_status.execute_routing.find { |r| r.match?(current_host, host_role) }
            return pipeline_callable.call if routing.nil?

            @start_time_ns.set(nano_time)
            result = nil

            while routing && result.nil?
              result = routing.apply(method_name, @wrapper_props, storage_service)

              next unless result.nil?

              @bg_status = storage_service.get(BLUE_GREEN_NAME, @bgd_id)
              if @bg_status.nil?
                @end_time_ns.set(nano_time)
                return pipeline_callable.call
              end
              routing = @bg_status.execute_routing.find { |r| r.match?(current_host, host_role) }
            end

            @end_time_ns.set(nano_time)
            result.nil? ? pipeline_callable.call : result
          ensure
            @end_time_ns.set(nano_time) if @start_time_ns.get.positive? && @end_time_ns.get.zero?
          end
        end

        def hold_time_ns
          return 0 if @start_time_ns.get.zero?

          end_ns = @end_time_ns.get
          end_ns.zero? ? (nano_time - @start_time_ns.get) : (end_ns - @start_time_ns.get)
        end

        def reset_routing_time_ns
          @start_time_ns.set(0)
          @end_time_ns.set(0)
        end

        def self.clean_up_providers
          PROVIDERS.each_key { |k| PROVIDERS.delete(k)&.stop }
        end

        private

        def route_connect(host_info, driver_props, is_initial_connection, pipeline_callable)
          reset_routing_time_ns

          begin
            @bg_status = storage_service.get(BLUE_GREEN_NAME, @bgd_id)
            return regular_connect(pipeline_callable, is_initial_connection) if @bg_status.nil?

            host_role = @bg_status.role(host_info)
            return regular_connect(pipeline_callable, is_initial_connection) if host_role.nil?

            routing = @bg_status.connect_routing.find { |r| r.match?(host_info, host_role) }
            return regular_connect(pipeline_callable, is_initial_connection) if routing.nil?

            @start_time_ns.set(nano_time)
            conn = nil

            while routing && conn.nil?
              conn = routing.apply(host_info, driver_props, @wrapper_props, is_initial_connection, @service_container)

              next unless conn.nil?

              # Routing passed — re-read status in case it changed while we were waiting.
              @bg_status = storage_service.get(BLUE_GREEN_NAME, @bgd_id)
              if @bg_status.nil?
                @end_time_ns.set(nano_time)
                return regular_connect(pipeline_callable, is_initial_connection)
              end
              routing = @bg_status.connect_routing.find { |r| r.match?(host_info, host_role) }
            end

            @end_time_ns.set(nano_time)
            conn ||= pipeline_callable.call

            init_provider if is_initial_connection
            conn
          ensure
            @end_time_ns.set(nano_time) if @start_time_ns.get.positive? && @end_time_ns.get.zero?
          end
        end

        def regular_connect(pipeline_callable, is_initial_connection)
          conn = pipeline_callable.call
          init_provider if is_initial_connection
          conn
        end

        def init_provider
          return if @cluster_id && PROVIDERS.key?(@bgd_id)

          host_list_provider = @service_container.host_service.host_list_provider
          @cluster_id = host_list_provider.respond_to?(:cluster_id) ? host_list_provider.cluster_id :
                          @service_container.connection_service.config.cluster_id
          PROVIDERS.compute_if_absent(@bgd_id) do
            StatusProvider.new(@service_container, @wrapper_props, @bgd_id, @cluster_id)
          end
        end

        def storage_service
          @service_container.storage_service
        end

        def nano_time
          Process.clock_gettime(Process::CLOCK_MONOTONIC, :nanosecond)
        end
      end
    end
  end
end
