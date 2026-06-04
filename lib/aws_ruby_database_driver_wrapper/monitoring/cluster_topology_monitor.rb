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

require_relative 'monitor'
require_relative 'monitor_connection'
require_relative '../host/host_role'
require_relative '../host/host_availability'
require_relative '../utils/events/monitor_reset_event'
require_relative '../property_definition'
require 'timeout'

module AwsRubyDatabaseDriverWrapper
  module Monitoring
    # Continuously monitors cluster topology, caches it in StorageService, and provides
    # fast writer re-discovery during failover via parallel host probing (panic mode).
    class ClusterTopologyMonitor < Monitor
      HIGH_REFRESH_DURATION_SEC = 30.0
      STABLE_TOPOLOGIES_DURATION_SEC = 15.0
      TOPOLOGY_CACHE_NAME = :topology
      INSTANCE_MONITOR_SLEEP_SEC = 0.1
      INITIAL_BACKOFF_SEC = 0.1
      MAX_BACKOFF_SEC = 10

      # @param service_container [Services::ServiceContainer]
      # @param cluster_id [String]
      # @param instance_template [Host::HostInfo]
      # @param topology_utils [Object] responds to #query_topology, #writer_instance?
      # @param monitoring_driver_props [Hash] driver props with prefixed driver overrides merged in
      # @param monitoring_wrapper_props [Hash] wrapper prop overrides extracted from prefixed props
      def initialize(
        service_container:,
        cluster_id:,
        instance_template:,
        topology_utils:,
        monitoring_driver_props:,
        monitoring_wrapper_props: {}
      )
        super(termination_timeout_sec: 30.0)

        @service_container = service_container
        @cluster_id = cluster_id
        @instance_template = instance_template
        @topology_utils = topology_utils
        @monitoring_driver_props = monitoring_driver_props
        @monitoring_wrapper_props = monitoring_wrapper_props

        props = service_container.connection_service.wrapper_props
        @refresh_rate_sec = PropertyDefinition::CLUSTER_TOPOLOGY_REFRESH_RATE_MS.get_int(props) / 1000.0
        @high_refresh_rate_sec = PropertyDefinition::CLUSTER_TOPOLOGY_HIGH_REFRESH_RATE_MS.get_int(props) / 1000.0
        @max_instance_monitors = PropertyDefinition::CLUSTER_TOPOLOGY_MAX_INSTANCE_MONITORS.get_int(props)

        @monitoring_connection = MonitorConnection.new
        @writer_info = nil
        @verified_writer = false
        @high_refresh_end_time = 0

        @topology_mutex = Mutex.new
        @topology_cv = ConditionVariable.new
        @update_requested = false

        @instance_monitors = {} # { host_string => Thread }
        @stop_instance_monitors = false
        @instance_monitors_writer_conn = MonitorConnection.new
        @panic_mutex = Mutex.new
        @instance_monitors_writer_info = nil
        @instance_monitor_topologies = {}
        # Tracks whether all instance monitors have completed at least one work cycle, even if an error occurs.
        # This guards against concluding all instance monitor topologies are stable before all of them have initialized.
        @completed_one_cycle = {}
        @latest_topology = nil
        @stable_start_time = 0
      end

      # Forces a topology refresh, ignoring any cached topology. Blocks until updated or raises on timeout.
      # @param verify_writer [Boolean] if true, enters panic mode to re-verify the writer.
      # @param timeout_ms [Integer] max time to wait for the update.
      # @return [Array<Host::HostInfo>] the updated topology.
      # @raise [Timeout::Error] if the topology is not updated within timeout_ms.
      def force_refresh(verify_writer, timeout_ms)
        if verify_writer
          @monitoring_connection.set(nil)
          @verified_writer = false
        end

        wait_for_topology_update(timeout_ms)
      end

      # Event subscriber callback.
      # @param event [Object]
      def process_event(event)
        return unless event.is_a?(Utils::Events::MonitorResetEvent)
        return unless event.cluster_id == @cluster_id

        # TODO(blue-green): When Blue/Green is implemented, check event.endpoints
        #   and only reset if this monitor's hosts overlap with the blue endpoints.
        reset!
      end

      def close
        close_instance_monitors
        @monitoring_connection.close
        @instance_monitors_writer_conn.close
      end

      private

      # Main monitoring loop.
      def monitor
        event_publisher.subscribe(self, Set[Utils::Events::MonitorResetEvent])
        logger.debug("[#{@cluster_id}] Started cluster topology monitor")

        until stopped?
          update_activity

          if panic_mode?
            run_panic_mode_iteration
          else
            run_regular_mode_iteration
          end
        end
      ensure
        @stop_instance_monitors = true
        close_instance_monitors
        @monitoring_connection.close
        @instance_monitors_writer_conn.close
        event_publisher.unsubscribe(self, Set[Utils::Events::MonitorResetEvent])
        logger.debug("[#{@cluster_id}] Stopped cluster topology monitor")
      end

      # --- Mode determination ---

      def panic_mode?
        @monitoring_connection.get.nil? || !@verified_writer
      end

      # --- Regular mode ---

      def run_regular_mode_iteration
        close_instance_monitors unless @instance_monitors.empty?

        hosts = fetch_topology_and_update_cache(@monitoring_connection.get)
        if hosts.nil?
          # Unable to fetch topology. Enter panic mode to find a reliable connection.
          @monitoring_connection.set(nil)
          @verified_writer = false
          @writer_info = nil
          return
        end

        @high_refresh_end_time = 0 if @high_refresh_end_time.positive? && monotonic_time > @high_refresh_end_time

        delay(use_high_rate: @high_refresh_end_time&.positive?)
      end

      # --- Panic mode ---

      def run_panic_mode_iteration
        if @instance_monitors.empty?
          start_instance_monitors
        else
          check_new_hosts_for_instance_monitors unless writer_picked_up_from_instance_monitors?
          check_stable_instance_monitor_topologies
        end

        delay(use_high_rate: true)
      end

      def start_instance_monitors
        @instance_monitors_writer_info = nil
        @latest_topology = nil
        cleanup_host_writer_connection

        hosts = stored_hosts || open_any_connection_and_update_topology
        # Close any previously running instance monitors.
        close_instance_monitors
        @stop_instance_monitors = false

        return if hosts.nil? || @verified_writer

        hosts.first(@max_instance_monitors).each do |host_info|
          spawn_instance_monitor(host_info)
        end
      end

      # Returns true if writer was picked up from instance monitors (caller should skip further checks).
      def writer_picked_up_from_instance_monitors?
        writer_conn = @instance_monitors_writer_conn.get
        writer_host = @instance_monitors_writer_info
        return false unless writer_conn && writer_host

        logger.info("[#{@cluster_id}] Writer found: #{writer_host.host}")
        @monitoring_connection.set(writer_conn, close_old: true)
        # Avoid double-close: clear host reference without closing since we transferred ownership.
        @instance_monitors_writer_conn.set(nil, close_old: false)
        @writer_info = writer_host
        @verified_writer = true
        @high_refresh_end_time = monotonic_time + HIGH_REFRESH_DURATION_SEC

        @stop_instance_monitors = true
        close_instance_monitors
        true
      end

      def check_new_hosts_for_instance_monitors
        hosts = @latest_topology
        return if hosts.nil? || @stop_instance_monitors

        hosts.first(@max_instance_monitors).each do |host_info|
          spawn_instance_monitor(host_info) unless @instance_monitors.key?(host_info.host) ||
                                                   @instance_monitors.size >= @max_instance_monitors
        end
      end

      def spawn_instance_monitor(host_info)
        thread = Thread.new { instance_monitor(host_info) }
        thread.name = "instance-monitor-#{host_info.host}"
        @instance_monitors[host_info.host] = thread
      end

      # --- Stable reader topologies consensus ---

      def check_stable_instance_monitor_topologies
        hosts = stored_hosts
        if hosts.nil? || hosts.empty?
          reset_stable_state
          return
        end

        monitored_ids = hosts.first(@max_instance_monitors).map(&:id)

        completed, topologies = @panic_mutex.synchronize { [@completed_one_cycle.dup, @instance_monitor_topologies.dup] }

        unless monitored_ids.all? { |id| completed[id] }
          reset_stable_state
          return
        end

        if topologies.empty?
          reset_stable_state
          return
        end

        # Check if all instance monitor topologies match (by host, port, role, availability).
        reference_topology = topologies.values.first
        all_match = topologies.values.all? do |topo|
          topo.size == reference_topology.size && topo.zip(reference_topology).all? do |a, b|
            a.host == b.host && a.port == b.port && a.role == b.role && a.availability == b.availability
          end
        end

        unless all_match
          reset_stable_state
          return
        end

        @stable_start_time = monotonic_time if @stable_start_time.zero?

        return unless monotonic_time > @stable_start_time + STABLE_TOPOLOGIES_DURATION_SEC

        @stable_start_time = 0
        update_hosts_availability(reference_topology)
        update_topology_cache(reference_topology)
        logger.debug("[#{@cluster_id}] Stable instance monitor topologies accepted")
      end

      def reset_stable_state
        @stable_start_time = 0
      end

      # --- Instance Monitor ---

      def instance_monitor(host_info)
        conn = nil
        connection_attempts = 0
        writer_changed = false

        until @stop_instance_monitors
          if conn.nil?
            conn = attempt_host_connection(host_info, connection_attempts)
            if conn.nil?
              connection_attempts += 1
              @panic_mutex.synchronize do
                @completed_one_cycle[host_info.id] = true
                @instance_monitor_topologies.delete(host_info.id)
              end
              next
            end
            connection_attempts = 0
          end

          role = check_host_role(conn)
          if role.nil?
            conn = nil
            next
          end

          if role == Host::HostRole::WRITER
            handle_writer_found(host_info, conn)
            return
          end

          # Reader path — writer_changed is sticky: once true, all subsequent fetches update the cache immediately.
          writer_changed = reader_fetch_topology(conn, host_info, writer_changed)
          @panic_mutex.synchronize { @completed_one_cycle[host_info.id] = true }
          sleep(INSTANCE_MONITOR_SLEEP_SEC)
        end
      rescue StandardError => e
        logger.debug("[#{@cluster_id}] Instance Monitor #{host_info.host}: #{e.message}")
      ensure
        @panic_mutex.synchronize do
          @completed_one_cycle[host_info.id] = true
          @instance_monitor_topologies.delete(host_info.id)
        end
        safe_close_connection(conn) if conn && conn != @instance_monitors_writer_conn.get
      end

      def attempt_host_connection(host_info, attempts)
        internal_connect(host_info)
      rescue StandardError => e
        logger.debug("[#{@cluster_id}] Connection to #{host_info.host} failed: #{e.message}")
        backoff = calculate_backoff(attempts)
        sleep(backoff)
        nil
      end

      def check_host_role(conn)
        @service_container.dialect_service.db_dialect.host_role(conn)
      rescue StandardError => e
        logger.debug("[#{@cluster_id}] host_role check failed: #{e.message}")
        nil
      end

      def handle_writer_found(host_info, conn)
        # If compare_and_set fails, another instance monitor already found the writer. Connection will be closed in
        # caller's ensure block.
        return unless @instance_monitors_writer_conn.compare_and_set(nil, conn)

        fetch_topology_and_update_cache(conn)
        host_info.availability = Host::HostAvailability::AVAILABLE
        @instance_monitors_writer_info = host_info
        @stop_instance_monitors = true
        logger.info("[#{@cluster_id}] Writer verified: #{host_info.host}")
      end

      def reader_fetch_topology(conn, host_info, writer_changed)
        hosts = query_topology(conn)
        return writer_changed if hosts.nil?

        @panic_mutex.synchronize do
          @latest_topology = hosts
          @instance_monitor_topologies[host_info.id] = hosts
        end

        if writer_changed
          update_hosts_availability(hosts)
          update_topology_cache(hosts)
          return true
        end

        latest_writer = hosts.find { |h| h.role == Host::HostRole::WRITER }
        if latest_writer && @writer_info &&
           latest_writer.host != @writer_info&.host
          logger.info("[#{@cluster_id}] Writer changed: #{@writer_info&.host} -> #{latest_writer.host}")
          update_hosts_availability(hosts)
          update_topology_cache(hosts)
          return true
        end

        writer_changed
      end

      # --- Topology operations ---

      def open_any_connection_and_update_topology
        existing_conn = @monitoring_connection.get
        return fetch_topology_and_update_cache(existing_conn) if existing_conn

        conn = internal_connect(initial_host_info)
        unless @monitoring_connection.compare_and_set(nil, conn)
          safe_close_connection(conn)
          return fetch_topology_and_update_cache(@monitoring_connection.get)
        end

        role = check_host_role(conn)
        if role == Host::HostRole::WRITER
          @verified_writer = true
          @writer_info = initial_host_info
        end

        hosts = fetch_topology_and_update_cache(conn)
        if hosts.nil?
          @monitoring_connection.set(nil)
          @verified_writer = false
          @writer_info = nil
        end
        hosts
      rescue StandardError => e
        logger.debug("[#{@cluster_id}] Failed to open monitoring connection: #{e.message}")
        nil
      end

      def fetch_topology_and_update_cache(conn)
        return nil if conn.nil?

        hosts = query_topology(conn)
        update_topology_cache(hosts) if hosts && !hosts.empty?
        hosts
      rescue StandardError => e
        logger.debug("[#{@cluster_id}] Topology fetch failed: #{e.message}")
        nil
      end

      def query_topology(conn)
        @topology_utils.query_topology(conn, @initial_host_info, @instance_template)
      end

      def stored_hosts
        storage_service.get(TOPOLOGY_CACHE_NAME, @cluster_id, register_access: false)
      end

      def update_topology_cache(hosts)
        @topology_mutex.synchronize do
          storage_service.set(TOPOLOGY_CACHE_NAME, @cluster_id, hosts)
          @update_requested = false
          @topology_cv.broadcast
        end
      end

      def clear_topology_cache
        @topology_mutex.synchronize do
          storage_service.remove(TOPOLOGY_CACHE_NAME, @cluster_id)
          @update_requested = false
          @topology_cv.broadcast
        end
      end

      def update_hosts_availability(hosts)
        return if hosts.nil? || hosts.empty?

        hosts.each do |host|
          available = @instance_monitor_topologies.key?(host.id)
          host.availability = available ? Host::HostAvailability::AVAILABLE : Host::HostAvailability::UNAVAILABLE
        end
      end

      # --- force_refresh support ---

      def wait_for_topology_update(timeout_ms)
        current_hosts = stored_hosts

        @topology_mutex.synchronize do
          @update_requested = true
          @topology_cv.broadcast
        end

        return current_hosts if timeout_ms.zero?

        deadline = monotonic_time + (timeout_ms / 1000.0)
        @topology_mutex.synchronize do
          # We are checking reference equality instead of value equality. We will break out of the loop if there is a
          # new entry in the topology cache, even if current_hosts contains the same hosts as stored_hosts.
          while stored_hosts.equal?(current_hosts) && monotonic_time < deadline && !stopped?
            remaining = deadline - monotonic_time
            break if remaining <= 0

            @topology_cv.wait(@topology_mutex, remaining)
          end
        end

        latest = stored_hosts
        raise Timeout::Error, "Topology not updated within #{timeout_ms}ms for cluster #{@cluster_id}" if latest.equal?(current_hosts)

        latest
      end

      # --- Reset ---

      def reset!
        logger.debug("[#{@cluster_id}] Monitor reset")
        @stop_instance_monitors = true
        close_instance_monitors
        @monitoring_connection.set(nil)
        @verified_writer = false
        @writer_info = nil
        @high_refresh_end_time = 0
        clear_topology_cache

        @topology_mutex.synchronize do
          @update_requested = true
          @topology_cv.broadcast
        end
      end

      # --- Cleanup helpers ---

      def close_instance_monitors
        @stop_instance_monitors = true
        @instance_monitors.each_value do |t|
          t.join(5)
          t.kill if t.alive?
        end
        @instance_monitors.clear
        cleanup_host_writer_connection
        @stable_start_time = 0
        @instance_monitor_topologies.clear
        @completed_one_cycle.clear
      end

      def cleanup_host_writer_connection
        # Avoid double-close if the monitoring connection already owns this reference.
        if @monitoring_connection.get.equal?(@instance_monitors_writer_conn.get)
          @instance_monitors_writer_conn.set(nil, close_old: false)
        else
          @instance_monitors_writer_conn.set(nil)
        end
      end

      # --- Delay ---

      def delay(use_high_rate:)
        use_high_rate = true if @high_refresh_end_time.positive? && monotonic_time < @high_refresh_end_time
        use_high_rate = true if @update_requested

        duration = use_high_rate ? @high_refresh_rate_sec : @refresh_rate_sec

        @topology_mutex.synchronize do
          @topology_cv.wait(@topology_mutex, duration) unless @update_requested || stopped?
        end
      end

      # --- Utilities ---

      def monotonic_time
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end

      def safe_close_connection(conn)
        conn&.close
      rescue StandardError
        nil
      end

      def calculate_backoff(attempt)
        backoff = INITIAL_BACKOFF_SEC * (2**[attempt, 6].min)
        backoff = [backoff, MAX_BACKOFF_SEC].min
        backoff * (0.5 + (rand * 0.5))
      end

      def event_publisher
        @service_container.event_publisher
      end

      def storage_service
        @service_container.storage_service
      end

      def initial_host_info
        @service_container.connection_service.initial_host_info
      end

      def internal_connect(host_info)
        @service_container.plugin_manager.internal_connect(host_info, @monitoring_driver_props, @monitoring_wrapper_props, false)
      end
    end
  end
end
