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
      HOST_WORKER_SLEEP_SEC = 0.1
      INITIAL_BACKOFF_MS = 100
      MAX_BACKOFF_MS = 10_000

      # @param service_container [Services::ServiceContainer]
      # @param cluster_id [String]
      # @param instance_template [Host::HostInfo]
      # @param topology_utils [Object] responds to #query_topology, #writer_instance?
      # @param connect_func [Proc] ->(host_info) { connection }
      def initialize(
        service_container:,
        cluster_id:,
        instance_template:,
        topology_utils:,
        connect_func:
      )
        super(termination_timeout_sec: 30.0)

        @service_container = service_container
        @cluster_id = cluster_id
        @instance_template = instance_template
        @topology_utils = topology_utils
        @connect_func = connect_func

        props = service_container.connection_service.config.wrapper_props
        @refresh_rate_sec = PropertyDefinition::CLUSTER_TOPOLOGY_REFRESH_RATE_MS.get_int(props) / 1000.0
        @high_refresh_rate_sec = PropertyDefinition::CLUSTER_TOPOLOGY_HIGH_REFRESH_RATE_MS.get_int(props) / 1000.0
        @max_host_threads = PropertyDefinition::CLUSTER_TOPOLOGY_MAX_NODE_THREADS.get_int(props)

        @monitoring_connection = MonitorConnection.new
        @writer_host_info = nil
        @verified_writer = false
        @high_refresh_end_time = 0

        @topology_mutex = Mutex.new
        @topology_cv = ConditionVariable.new
        @request_to_update = false

        @host_threads = []
        @host_threads_stop = false
        @host_writer_connection = MonitorConnection.new
        @host_writer_host_info = nil
        @reader_topologies = {}
        @completed_one_cycle = {}
        @latest_topology = nil
        @stable_start_time = 0
        @submitted_hosts = {}
      end

      # Forces a topology refresh. Blocks until updated or raises on timeout.
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
        close_host_workers
        @monitoring_connection.close
        @host_writer_connection.close
      end

      private

      # Main monitoring loop — called by the base Monitor class in a dedicated thread.
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
        @host_threads_stop = true
        close_host_workers
        @monitoring_connection.close
        @host_writer_connection.close
        event_publisher.unsubscribe(self, Set[Utils::Events::MonitorResetEvent])
        logger.debug("[#{@cluster_id}] Stopped cluster topology monitor")
      end

      # --- Mode determination ---

      def panic_mode?
        @monitoring_connection.get.nil? || !@verified_writer
      end

      # --- Regular mode ---

      def run_regular_mode_iteration
        cleanup_host_workers unless @submitted_hosts.empty?

        hosts = fetch_topology_and_update_cache(@monitoring_connection.get)
        if hosts.nil?
          @monitoring_connection.set(nil)
          @verified_writer = false
          @writer_host_info = nil
          return
        end

        @high_refresh_end_time = 0 if @high_refresh_end_time.positive? && monotonic_time > @high_refresh_end_time

        delay(use_high_rate: @high_refresh_end_time.positive?)
      end

      # --- Panic mode ---

      def run_panic_mode_iteration
        if @submitted_hosts.empty?
          start_host_workers
        else
          writer_picked_up_from_workers? || check_new_hosts_for_workers
          check_stable_reader_topologies
        end

        delay(use_high_rate: true)
      end

      def start_host_workers
        @host_writer_host_info = nil
        @latest_topology = nil
        host_writer_connection_cleanup

        hosts = stored_hosts || open_any_connection_and_update_topology
        close_host_workers
        @host_threads_stop = false

        return if hosts.nil? || @verified_writer

        hosts.first(@max_host_threads).each do |host_info|
          spawn_host_worker(host_info)
        end
      end

      # Returns true if writer was picked up from workers (caller should skip further checks).
      def writer_picked_up_from_workers?
        writer_conn = @host_writer_connection.get
        writer_host = @host_writer_host_info
        return false unless writer_conn && writer_host

        logger.info("[#{@cluster_id}] Writer found: #{writer_host.host}")
        @monitoring_connection.set(writer_conn, close_old: true)
        # Avoid double-close: clear host reference without closing since we transferred ownership.
        @host_writer_connection.set(nil, close_old: false)
        @writer_host_info = writer_host
        @verified_writer = true
        @high_refresh_end_time = monotonic_time + HIGH_REFRESH_DURATION_SEC

        @host_threads_stop = true
        close_host_workers
        reset_panic_state
        true
      end

      def check_new_hosts_for_workers
        hosts = @latest_topology
        return if hosts.nil? || @host_threads_stop

        hosts.first(@max_host_threads).each do |host_info|
          spawn_host_worker(host_info) unless @submitted_hosts.key?(host_info.host)
        end
      end

      def spawn_host_worker(host_info)
        return if @submitted_hosts.size >= @max_host_threads

        @submitted_hosts[host_info.host] = true
        thread = Thread.new { host_monitoring_worker(host_info) }
        thread.name = "host-monitor-#{host_info.host}"
        @host_threads << thread
      end

      # --- Stable reader topologies consensus ---

      def check_stable_reader_topologies
        hosts = stored_hosts
        return reset_stable_state if hosts.nil? || hosts.empty?

        reader_ids = hosts.map(&:id)
        reader_ids.each do |id|
          return reset_stable_state unless @completed_one_cycle[id]
        end

        return reset_stable_state if @reader_topologies.empty?

        # Check if all reader topologies match (by host, port, role, availability).
        canonical = @reader_topologies.values.first
        all_match = @reader_topologies.values.all? do |topo|
          topo.size == canonical.size && topo.zip(canonical).all? do |a, b|
            a.host == b.host && a.port == b.port && a.role == b.role && a.availability == b.availability
          end
        end

        return reset_stable_state unless all_match

        @stable_start_time = monotonic_time if @stable_start_time.zero?

        return unless monotonic_time > @stable_start_time + STABLE_TOPOLOGIES_DURATION_SEC

        @stable_start_time = 0
        update_hosts_availability(canonical)
        update_topology_cache(canonical)
        logger.debug("[#{@cluster_id}] Stable reader topologies accepted")
      end

      def reset_stable_state
        @stable_start_time = 0
      end

      # --- Host monitoring worker (runs in its own thread) ---

      def host_monitoring_worker(host_info)
        conn = nil
        connection_attempts = 0
        writer_changed = false

        until @host_threads_stop
          if conn.nil?
            conn = attempt_host_connection(host_info, connection_attempts)
            if conn.nil?
              connection_attempts += 1
              @completed_one_cycle[host_info.id] = true
              @reader_topologies.delete(host_info.id)
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

          # Reader path
          writer_changed = reader_fetch_topology(conn, host_info, writer_changed)
          @completed_one_cycle[host_info.id] = true
          sleep(HOST_WORKER_SLEEP_SEC)
        end
      rescue StandardError => e
        logger.debug("[#{@cluster_id}] Host worker #{host_info.host}: #{e.message}")
      ensure
        @completed_one_cycle[host_info.id] = true
        @reader_topologies.delete(host_info.id)
        safe_close_connection(conn) if conn && conn != @host_writer_connection.get
      end

      def attempt_host_connection(host_info, attempts)
        @connect_func.call(host_info)
      rescue StandardError => e
        logger.debug("[#{@cluster_id}] Connection to #{host_info.host} failed: #{e.message}")
        backoff = calculate_backoff(attempts)
        sleep(backoff / 1000.0)
        nil
      end

      def check_host_role(conn)
        @service_container.dialect_service.db_dialect.host_role(conn)
      rescue StandardError => e
        logger.debug("[#{@cluster_id}] host_role check failed: #{e.message}")
        nil
      end

      def handle_writer_found(host_info, conn)
        return unless @host_writer_connection.compare_and_set(nil, conn)

        fetch_topology_and_update_cache(conn)
        host_info.availability = Host::HostAvailability::AVAILABLE
        @host_writer_host_info = host_info
        @host_threads_stop = true
        logger.info("[#{@cluster_id}] Writer verified: #{host_info.host}")

        # If CAS failed, another worker already found the writer. Connection will be closed in ensure.
      end

      def reader_fetch_topology(conn, host_info, writer_changed)
        hosts = query_topology(conn)
        return writer_changed if hosts.nil?

        @latest_topology = hosts
        @reader_topologies[host_info.id] = hosts

        if writer_changed
          update_hosts_availability(hosts)
          update_topology_cache(hosts)
          return true
        end

        latest_writer = hosts.find { |h| h.role == Host::HostRole::WRITER }
        if latest_writer && @writer_host_info &&
           latest_writer.host != @writer_host_info.host
          logger.info("[#{@cluster_id}] Writer changed: #{@writer_host_info.host} -> #{latest_writer.host}")
          update_hosts_availability(hosts)
          update_topology_cache(hosts)
          return true
        end

        writer_changed
      end

      # --- Topology operations ---

      def open_any_connection_and_update_topology
        return stored_hosts if @monitoring_connection.get

        conn = @connect_func.call(initial_host_info)
        unless @monitoring_connection.compare_and_set(nil, conn)
          safe_close_connection(conn)
          return fetch_topology_and_update_cache(@monitoring_connection.get)
        end

        role = check_host_role(conn)
        if role == Host::HostRole::WRITER
          @verified_writer = true
          @writer_host_info = initial_host_info
        end

        hosts = fetch_topology_and_update_cache(@monitoring_connection.get)
        if hosts.nil?
          @monitoring_connection.set(nil)
          @verified_writer = false
          @writer_host_info = nil
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
        @topology_utils.query_topology(conn, @instance_template, @instance_template)
      end

      def stored_hosts
        storage_service.get(TOPOLOGY_CACHE_NAME, @cluster_id, register_access: false)
      end

      def update_topology_cache(hosts)
        @topology_mutex.synchronize do
          storage_service.set(TOPOLOGY_CACHE_NAME, @cluster_id, hosts)
          @request_to_update = false
          @topology_cv.broadcast
        end
      end

      def clear_topology_cache
        @topology_mutex.synchronize do
          storage_service.remove(TOPOLOGY_CACHE_NAME, @cluster_id)
          @request_to_update = false
          @topology_cv.broadcast
        end
      end

      def update_hosts_availability(hosts)
        return if hosts.nil? || hosts.empty?

        hosts.each do |host|
          host.availability = if @reader_topologies.key?(host.id)
                                Host::HostAvailability::AVAILABLE
                              else
                                Host::HostAvailability::UNAVAILABLE
                              end
        end
      end

      # --- force_refresh support ---

      def wait_for_topology_update(timeout_ms)
        current_hosts = stored_hosts

        @topology_mutex.synchronize do
          @request_to_update = true
          @topology_cv.broadcast
        end

        return current_hosts if timeout_ms.zero?

        deadline = monotonic_time + (timeout_ms / 1000.0)
        @topology_mutex.synchronize do
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
        @host_threads_stop = true
        close_host_workers
        host_writer_connection_cleanup
        @monitoring_connection.set(nil)
        @verified_writer = false
        @writer_host_info = nil
        @high_refresh_end_time = 0
        reset_panic_state
        clear_topology_cache

        @topology_mutex.synchronize do
          @request_to_update = true
          @topology_cv.broadcast
        end
      end

      # --- Cleanup helpers ---

      def reset_panic_state
        @submitted_hosts.clear
        @stable_start_time = 0
        @reader_topologies.clear
        @completed_one_cycle.clear
      end

      def close_host_workers
        @host_threads_stop = true
        @host_threads.each do |t|
          t.join(5)
          t.kill if t.alive?
        end
        @host_threads.clear
        host_writer_connection_cleanup
      end

      def cleanup_host_workers
        close_host_workers
        reset_panic_state
      end

      def host_writer_connection_cleanup
        # Avoid double-close if the monitoring connection already owns this reference.
        if @monitoring_connection.get.equal?(@host_writer_connection.get)
          @host_writer_connection.set(nil, close_old: false)
        else
          @host_writer_connection.set(nil)
        end
      end

      # --- Delay ---

      def delay(use_high_rate:)
        use_high_rate = true if @high_refresh_end_time.positive? && monotonic_time < @high_refresh_end_time
        use_high_rate = true if @request_to_update

        duration = use_high_rate ? @high_refresh_rate_sec : @refresh_rate_sec

        @topology_mutex.synchronize do
          @topology_cv.wait(@topology_mutex, duration) unless @request_to_update || stopped?
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
        backoff = INITIAL_BACKOFF_MS * (2**[attempt, 6].min)
        backoff = [backoff, MAX_BACKOFF_MS].min
        (backoff * (0.5 + (rand * 0.5))).round
      end

      def event_publisher
        @service_container.event_publisher
      end

      def storage_service
        @service_container.storage_service
      end

      def initial_host_info
        @service_container.connection_service.config.initial_host_info
      end
    end
  end
end
