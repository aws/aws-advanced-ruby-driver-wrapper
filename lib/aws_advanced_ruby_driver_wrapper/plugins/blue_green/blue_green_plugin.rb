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
require_relative 'drop_blue_connections_marker'
require_relative 'phase'
require_relative 'role'
require_relative 'status'
require_relative 'status_provider'

module AwsAdvancedRubyDriverWrapper
  module Plugins
    module BlueGreen
      class BlueGreenPlugin
        include Logging

        BLUE_GREEN_NAME = :blue_green

        # Storage partition for the drop-blue-connections marker, kept separate from BLUE_GREEN_NAME so
        # it can outlive the status cache's TTL. The marker is stored once per switchover and never
        # re-stamped, so a connection that sits idle longer than the status cache's TTL must still find
        # the marker on its next use. A long TTL is safe: a marker only matches connections opened before
        # its own switchover, and a later switchover overwrites it.
        DROP_MARKER_NAME = :blue_green_drop_marker
        DROP_MARKER_TTL_SEC = 86_400

        # When present in wrapper_props, internal_connect calls bypass BG routing.
        # Used by BG monitoring connections to avoid being intercepted by their own plugin.
        BG_SKIP_ROUTING_KEY = :'bg.skip_routing'

        CLOSING_METHODS = Set[
          RubyMethod::CONNECTION_CLOSE.name,
          RubyMethod::STATEMENT_CLOSE.name
        ].freeze

        PROVIDERS = Concurrent::Map.new

        # Storage key, within the DROP_MARKER_NAME cache, under which the drop-blue-connections marker
        # for a deployment is kept. DROP_MARKER_NAME is a separate partition from the status cache, so
        # the marker survives both the status cache's TTL and the provider's reset_context_when_completed.
        def self.drop_marker_key(bgd_id)
          "#{bgd_id}::drop_blue_connections_marker"
        end

        def initialize(service_container, props = ::Concurrent::Map.new)
          @service_container = service_container
          @wrapper_props = props
          @bgd_id = PropertyDefinition::BGD_ID.get(props).to_s.strip.downcase
          @bg_status = nil
          @cluster_id = nil
          @start_time_ns = Concurrent::AtomicReference.new(0)
          @end_time_ns = Concurrent::AtomicReference.new(0)

          # Per-connection drop-blue-connections state. Each wrapper client has its own plugin instance,
          # so these describe this connection: when it was opened, the host it was opened to, and the
          # identity of the last marker it was checked against.
          @drop_blue_connections = PropertyDefinition::BG_DROP_BLUE_CONNECTIONS.get_bool(props)
          @connection_open_time_ns = nil
          @connect_time_host = nil
          @checked_drop_marker_id = nil
          @pending_stale_marker_id = nil

          service_container.storage_service.register(BLUE_GREEN_NAME, ttl: 3600)
          service_container.storage_service.register(DROP_MARKER_NAME, ttl: DROP_MARKER_TTL_SEC)

          network_methods = service_container.dialect_service.driver_dialect.network_bound_methods
          @subscribed_methods = (Set['connect', 'internal_connect'] | network_methods).freeze
        end

        attr_reader :subscribed_methods

        def connect(host_info, driver_props, is_initial_connection, pipeline_callable)
          route_connect(host_info, driver_props, is_initial_connection, pipeline_callable, is_internal: false)
        end

        def internal_connect(host_info, driver_props, wrapper_props, is_initial_connection, pipeline_callable)
          # BG monitoring connections set BG_SKIP_ROUTING_KEY to bypass routing.
          return pipeline_callable.call if wrapper_props[BG_SKIP_ROUTING_KEY]

          route_connect(host_info, driver_props, is_initial_connection, pipeline_callable, is_internal: true)
        end

        def execute(method_name, pipeline_callable, *_, **, &)
          reset_routing_time_ns

          begin
            init_provider

            return pipeline_callable.call if CLOSING_METHODS.include?(method_name)

            # Read the status before the stale check. The provider stores the active drop marker before
            # it writes the POST/COMPLETED status, so reading status first closes the race where a stale
            # check sees a still-pending marker and the COMPLETED early return below then skips re-checking
            # the now-active marker: if the switchover has completed, the check below sees the active marker.
            @bg_status = storage_service.get(BLUE_GREEN_NAME, @bgd_id)

            # Invalidate a connection opened to the old blue environment before a confirmed switchover,
            # so the failover plugin reconnects through BG routing instead of serving a stale read. This
            # runs before the NOT_CREATED/COMPLETED early return below, because after the switchover the
            # status is COMPLETED (then NOT_CREATED) and would otherwise skip the check entirely.
            if stale_blue_connection?
              invalidate_stale_blue_connection
              return pipeline_callable.call
            end

            if @bg_status.nil? || @bg_status.current_phase == Phase::NOT_CREATED || @bg_status.current_phase == Phase::COMPLETED
              return pipeline_callable.call
            end

            current_host = @service_container.connection_service.current_host_info
            host_role = @bg_status.role(current_host)
            return pipeline_callable.call if host_role.nil?

            routing = @bg_status.execute_routing.find { |r| r.match?(current_host, host_role) }
            return pipeline_callable.call if routing.nil?

            @start_time_ns.set(nano_time)
            result = nil

            while routing && result.nil?
              result = routing.apply(method_name, @wrapper_props, storage_service, telemetry_factory: @service_container.telemetry_factory)

              next unless result.nil?

              @bg_status = storage_service.get(BLUE_GREEN_NAME, @bgd_id)
              break if @bg_status.nil?

              routing = @bg_status.execute_routing.find { |r| r.match?(current_host, host_role) }
            end

            @end_time_ns.set(nano_time)
            return result unless result.nil?

            # The call may have been held through the switchover (e.g. suspended during IN_PROGRESS and
            # released at POST, which has no execute routing). Re-check whether this connection is now a
            # stale blue connection before running it, so a held call is not run against retired blue.
            invalidate_stale_blue_connection if stale_blue_connection?
            pipeline_callable.call
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

        # Forgets the providers inherited by a forked child so the child starts its own on first use.
        # A provider that fails to release is still forgotten, and the rest are released.
        def self.release_providers_after_fork
          PROVIDERS.each_key do |key|
            PROVIDERS.delete(key)&.release_after_fork
          rescue StandardError => e
            AwsAdvancedRubyDriverWrapper.logger.warn("Failed to release Blue/Green status provider #{key} after fork: #{e.message}")
          end
        end

        private

        def route_connect(host_info, driver_props, is_initial_connection, pipeline_callable, is_internal: false)
          reset_routing_time_ns

          begin
            @bg_status = storage_service.get(BLUE_GREEN_NAME, @bgd_id)
            return regular_connect(pipeline_callable, is_initial_connection, host_info) if @bg_status.nil?

            host_role = @bg_status.role(host_info)
            return regular_connect(pipeline_callable, is_initial_connection, host_info) if host_role.nil?

            routing = @bg_status.connect_routing.find { |r| r.match?(host_info, host_role) }
            return regular_connect(pipeline_callable, is_initial_connection, host_info) if routing.nil?

            @start_time_ns.set(nano_time)
            conn = nil

            while routing && conn.nil?
              # Pass self so a routing that opens a substitute connection can skip this plugin in the
              # nested pipeline, preventing the connect path from re-entering BG routing (infinite recursion).
              conn = routing.apply(host_info, driver_props, @wrapper_props, is_initial_connection, @service_container,
                                   is_internal: is_internal, bg_plugin: self)

              next unless conn.nil?

              # Routing passed — re-read status in case it changed while we were waiting.
              @bg_status = storage_service.get(BLUE_GREEN_NAME, @bgd_id)
              if @bg_status.nil?
                @end_time_ns.set(nano_time)
                return regular_connect(pipeline_callable, is_initial_connection, host_info)
              end
              routing = @bg_status.connect_routing.find { |r| r.match?(host_info, host_role) }
            end

            @end_time_ns.set(nano_time)
            conn ||= pipeline_callable.call

            record_connection_open(host_info)
            init_provider if is_initial_connection
            conn
          ensure
            @end_time_ns.set(nano_time) if @start_time_ns.get.positive? && @end_time_ns.get.zero?
          end
        end

        def regular_connect(pipeline_callable, is_initial_connection, host_info)
          conn = pipeline_callable.call
          record_connection_open(host_info)
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

        # Remembers when this connection was opened and the host it was opened to, so a later switchover
        # can tell whether it is a blue connection that predates the switchover.
        def record_connection_open(host_info)
          return unless @drop_blue_connections

          @connection_open_time_ns = nano_time
          @connect_time_host = host_info&.host&.downcase
          # A (re)connect produces a fresh connection (e.g. after failover): reset the per-connection
          # marker latches so this new incarnation re-evaluates the current marker from a clean slate
          # instead of inheriting the retired connection's checked/pending state.
          @checked_drop_marker_id = nil
          @pending_stale_marker_id = nil
        end

        # Whether this connection should be invalidated because it was opened to the old blue environment
        # before a now-confirmed switchover. The marker is read on every call so a later switchover's
        # marker is noticed. A marker that does not apply to this connection is latched immediately and
        # never re-examined; a marker that does apply is only latched once #invalidate_stale_blue_connection
        # confirms the close, so a transient close failure leaves the connection to be invalidated again on
        # its next use instead of silently serving stale reads for the rest of its life.
        def stale_blue_connection?
          return false unless @drop_blue_connections

          marker = storage_service.get(DROP_MARKER_NAME, self.class.drop_marker_key(@bgd_id), register_access: false)
          return false unless marker.is_a?(DropBlueConnectionsMarker) && marker.active?
          return false if marker.id == @checked_drop_marker_id

          if marker.stale?(@connect_time_host, @connection_open_time_ns)
            @pending_stale_marker_id = marker.id
            true
          else
            # This connection does not predate the switchover and never will against this marker (markers
            # are immutable), so latch it now to skip re-reading the marker on every future call.
            @checked_drop_marker_id = marker.id
            false
          end
        end

        # Closes the connection directly through the driver dialect rather than the pipeline's close
        # method. Going through the pipeline would set the failover plugin's @closed_explicitly, which
        # would stop it from reconnecting. Closing it out from under the pipeline instead lets the
        # failover plugin (if enabled) see a connection closed that it did not close, fail over, and
        # raise FailoverSuccessError; without failover the driver raises its closed-connection error.
        def invalidate_stale_blue_connection
          logger.info do
            "[bgd_id: '#{@bgd_id}'] Invalidating a connection to #{@connect_time_host} from the old blue environment " \
              'retired by a Blue/Green switchover. It will fail over (or raise a closed-connection error) on this use.'
          end

          conn = @service_container.connection_service.current_connection
          @service_container.dialect_service.driver_dialect.close_connection(conn) unless conn.nil?
          # Only now that the close is confirmed do we latch the marker as handled. If the close raised
          # and was swallowed below, the marker stays unlatched so the next use retries the invalidation
          # rather than serving a stale read from retired blue for the rest of the connection's life.
          @checked_drop_marker_id = @pending_stale_marker_id
        rescue StandardError => e
          logger.debug { "[bgd_id: '#{@bgd_id}'] Failed to invalidate stale blue connection: #{e.class}: #{e.message}" }
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
