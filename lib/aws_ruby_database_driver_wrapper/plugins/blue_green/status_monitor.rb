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
require 'resolv'
require_relative '../../logging'
require_relative '../../monitoring/monitor'
require_relative '../../monitoring/monitor_connection'
require_relative '../../property_definition'
require_relative '../../utils/rds_utils'
require_relative '../../utils/connection_config'
require_relative '../../services/connection_service'
require_relative '../../services/service_container'
require_relative '../../host/rds_host_list_provider'
require_relative 'phase'
require_relative 'role'
require_relative 'status_info'
require_relative 'interim_status'
require_relative 'interval_rate'

module AwsRubyDatabaseDriverWrapper
  module Plugins
    module BlueGreen
      # Background thread that monitors the Blue/Green status table for one role (SOURCE or TARGET).
      class StatusMonitor < Monitoring::Monitor
        include Logging

        TERMINATION_TIMEOUT_SEC = 30.0
        BG_CLUSTER = PropertyDefinition::BG_STORAGE_NAMESPACE
        DEFAULT_CHECK_INTERVAL_MS = 100
        LATEST_KNOWN_VERSION = '1.0'
        KNOWN_VERSIONS = Set[LATEST_KNOWN_VERSION].freeze

        def initialize(
          role,
          bgd_id,
          initial_host,
          service_container,
          monitoring_driver_props:,
          status_check_interval_map:,
          on_change_func:,
          monitoring_wrapper_props: {}
        )
          super(termination_timeout_sec: TERMINATION_TIMEOUT_SEC)

          @role = role
          @bgd_id = bgd_id.freeze
          @initial_host = initial_host.freeze
          @service_container = service_container
          @status_monitor_driver_props = monitoring_driver_props
          @status_monitor_wrapper_props = monitoring_wrapper_props
          @status_check_interval_map = status_check_interval_map
          @on_change_func = on_change_func

          @current_phase = Phase::NOT_CREATED
          @version = LATEST_KNOWN_VERSION
          @port = -1
          @connection = Monitoring::MonitorConnection.new(service_container.dialect_service.driver_dialect)
          @use_ip_address = Concurrent::AtomicBoolean.new(false)
          @panic_mode = Concurrent::AtomicBoolean.new(true)
          @correct_connection_host = Concurrent::AtomicBoolean.new(false)
          @connected_ip_address = Concurrent::AtomicReference.new(nil)
          @start_ip_addresses_by_host_map = Concurrent::Hash.new
          @connection_host_info = Concurrent::AtomicReference.new(nil)
          @open_connection_future = Concurrent::AtomicReference.new(nil)
          @event = Concurrent::Event.new
          @interval_rate = Concurrent::AtomicReference.new(IntervalRate::BASELINE)
          @current_topology = Concurrent::AtomicReference.new(nil)
          @start_topology = nil
          @collect_topology = Concurrent::AtomicBoolean.new(true)
          @collect_ip_addresses = Concurrent::AtomicBoolean.new(true)
          @host_names = Set.new
          @current_ip_addresses_by_host_map = Concurrent::Hash.new
          @all_start_topology_ip_changed = false
          @all_start_topology_endpoints_removed = false
          @all_topology_changed = false
        end

        def monitor
          loop do
            break if stopped?

            begin
              old_phase = @current_phase
              open_connection
              collect_status
              collect_topology
              collect_host_ip_addresses
              update_ip_address_flags

              logger.debug { "[#{@role}] Status changed to: #{@current_phase}" } if @current_phase && @current_phase != old_phase

              @on_change_func&.call(
                @role,
                InterimStatus.new(
                  @current_phase,
                  @version,
                  @port,
                  @start_topology&.dup,
                  @current_topology.get&.dup,
                  @start_ip_addresses_by_host_map.dup,
                  @current_ip_addresses_by_host_map.dup,
                  @host_names.dup,
                  @all_start_topology_ip_changed,
                  @all_start_topology_endpoints_removed,
                  @all_topology_changed
                )
              )

              delay_ms = @status_check_interval_map.fetch(
                @panic_mode.true? ? IntervalRate::HIGH : @interval_rate.get,
                DEFAULT_CHECK_INTERVAL_MS
              )
              delay(delay_ms)
            rescue Interrupt => e
              logger.debug { "[#{@role}] Interrupted." }
              Thread.current.raise(e)
            rescue StandardError => e
              logger.warn { "[#{@role}] Unhandled exception while monitoring blue/green status: #{e.class}: #{e.message}" }
            end
          end
        ensure
          @connection.close
          @host_list_provider&.stop_monitor if @host_list_provider.respond_to?(:stop_monitor)
          @host_list_provider = nil
          @open_connection_future.set(nil)
          logger.debug { "[#{@role}] Blue/green status monitoring thread is completed." }
        end

        def open_connection
          connection = @connection.get
          return unless connection.nil? || connection_closed?(connection)

          future = @open_connection_future.get
          if future
            if future.resolved?
              return if @panic_mode.false?
            elsif future.pending?
              return
            end
            # future is rejected — fall through to replace it
          end

          new_future = Concurrent::Promises.future { attempt_open_connection }
          @open_connection_future.compare_and_set(future, new_future)
        end

        def resolve_ip_address(host)
          Resolv.getaddress(host)
        rescue Resolv::ResolvError
          nil
        end

        # Attempts to connect to all known instance IPs in parallel and returns the first
        # successful connection.
        def try_connect_on_all_instances(host_info)
          prev_ip = @connected_ip_address.get
          candidate_ips = @start_ip_addresses_by_host_map.values.compact.to_set
          candidate_ips.add(prev_ip) if prev_ip

          return nil if candidate_ips.empty?

          logger.debug { "[#{@role}] Opening monitoring connection (IP) to #{candidate_ips.to_a.join(', ')}." }
          connect_to_first_available_ip(candidate_ips, host_info)
        end

        def connect_to_first_available_ip(candidate_ips, host_info)
          winner = Concurrent::AtomicReference.new(nil)

          futures = candidate_ips.map do |ip|
            Concurrent::Promises.future do
              conn = try_connect_single_ip_address(ip, host_info)
              if conn && !winner.compare_and_set(nil, conn)
                begin
                  @service_container.dialect_service.driver_dialect.close_connection(conn)
                rescue StandardError
                  nil
                end
              end
            end
          end

          Concurrent::Promises.zip(*futures).wait(TERMINATION_TIMEOUT_SEC)
          winner.get
        end

        def try_connect_single_ip_address(ip_address, host_info)
          original_host = host_info.host
          host_info = host_info.deep_dup
          host_info.host = ip_address

          connect_props = @status_monitor_driver_props.dup
          override_props = iam_enabled? ? map_merge(@status_monitor_wrapper_props, PropertyDefinition::IAM_HOST.name => original_host)
                             : @status_monitor_wrapper_props

          logger.debug { "[#{@role}] Opening monitoring connection (IP) to #{ip_address}." }

          connection = @service_container.plugin_manager.internal_connect(
            host_info, connect_props, override_props, false
          )
          @connected_ip_address.set(ip_address)
          connection
        rescue StandardError
          nil
        end

        def delay(delay_ms)
          end_time = Process.clock_gettime(Process::CLOCK_MONOTONIC, :millisecond) + delay_ms
          current_interval_rate = @interval_rate.get
          current_panic = @panic_mode.true?
          min_delay = [delay_ms, 50].min / 1000.0

          loop do
            @event.wait(min_delay)
            break if @interval_rate.get != current_interval_rate ||
                     Process.clock_gettime(Process::CLOCK_MONOTONIC, :millisecond) >= end_time ||
                     @stop_flag.true? ||
                     current_panic != @panic_mode.true?
          end
        end

        def update_ip_address_flags
          if @collect_topology.true?
            @all_start_topology_ip_changed = false
            @all_start_topology_endpoints_removed = false
            @all_topology_changed = false
            return
          end

          unless @collect_ip_addresses.true?
            @all_start_topology_ip_changed = @start_topology&.any? &&
                                             @start_topology.all? do |x|
                                               start_ip = @start_ip_addresses_by_host_map[x.host]
                                               current_ip = @current_ip_addresses_by_host_map[x.host]
                                               start_ip && current_ip && start_ip != current_ip
                                             end
          end

          @all_start_topology_endpoints_removed = @start_topology&.any? &&
                                                  @start_topology.all? do |x|
                                                    start_ip = @start_ip_addresses_by_host_map[x.host]
                                                    current_ip = @current_ip_addresses_by_host_map[x.host]
                                                    start_ip && current_ip.nil?
                                                  end

          start_hosts = @start_topology&.to_set(&:host) || Set.new
          current_topology = @current_topology.get
          @all_topology_changed = current_topology&.any? &&
                                  start_hosts.any? &&
                                  current_topology.none? { |x| start_hosts.include?(x.host) }
        end

        def collect_host_ip_addresses
          @current_ip_addresses_by_host_map.clear

          @host_names.each do |host|
            @current_ip_addresses_by_host_map[host] = resolve_ip_address(host)
          end

          @start_ip_addresses_by_host_map.replace(@current_ip_addresses_by_host_map) if @collect_ip_addresses.true?
        end

        def collect_topology
          return if @host_list_provider.nil?

          conn = @connection.get
          return if conn.nil? || connection_closed?(conn)

          topology = @host_list_provider.force_refresh(false, Host::RdsHostListProvider::DEFAULT_TOPOLOGY_QUERY_TIMEOUT_SEC)
          return logger.debug { 'Timed out while waiting for force_refresh to return new topology info.' } if topology.nil?

          @current_topology.set(topology)

          return unless @collect_topology.true?

          @start_topology = topology
          @host_names.merge(topology.map(&:host))
        end

        def collect_status
          conn = @connection.get
          return if conn.nil? || connection_closed?(conn)

          return unless status_available?(conn)

          dialect = @service_container.dialect_service.db_dialect
          status_entries = parse_status_entries(conn, dialect)
          status_info = resolve_status_info(status_entries)
          apply_status_info(status_info, status_entries)
          verify_connection_host(status_info)
          init_host_list_provider if @correct_connection_host.true? && @host_list_provider.nil?
        rescue StandardError => e
          handle_collect_status_error(e, conn)
        end

        def collect_ip_addresses=(val)
          val ? @collect_ip_addresses.make_true : @collect_ip_addresses.make_false
        end

        def collect_topology=(val)
          val ? @collect_topology.make_true : @collect_topology.make_false
        end

        def use_ip_address=(val)
          val ? @use_ip_address.make_true : @use_ip_address.make_false
        end

        def interval_rate=(rate)
          @interval_rate.set(rate)
          notify_changes
        end

        def reset_collected_data
          @start_ip_addresses_by_host_map.clear
          @start_topology = nil
          @host_names.clear
        end

        def notify_changes
          @event.set
          @event.reset
        end

        private

        def attempt_open_connection
          @connection.set(nil)
          @panic_mode.make_true

          if @connection_host_info.get.nil?
            @connection_host_info.set(@initial_host)
            @connected_ip_address.set(nil)
            @correct_connection_host.make_false
          end

          host_info = @connection_host_info.get
          connected_ip = @connected_ip_address.get

          if @use_ip_address.true? && connected_ip
            established = try_connect_on_all_instances(host_info)
            unless established
              @connection.set(nil)
              @panic_mode.make_true
              notify_changes
              return
            end
            @connection.set(established)
            logger.debug { "[#{@role}] Opened monitoring connection (IP) to #{@connected_ip_address.get}." }
          else
            logger.debug { "[#{@role}] Opening monitoring connection to #{host_info.host}." }
            ip = resolve_ip_address(host_info.host)
            connect_props = @status_monitor_driver_props.dup
            override_props = iam_enabled? ? map_merge(@status_monitor_wrapper_props, PropertyDefinition::IAM_HOST.name => host_info.host)
                               : @status_monitor_wrapper_props
            @connection.set(@service_container.plugin_manager.internal_connect(
                              host_info, connect_props, override_props, false
                            ))
            @connected_ip_address.set(ip)
            logger.debug { "[#{@role}] Opened monitoring connection to #{host_info.host}." }
          end

          @panic_mode.make_false
          notify_changes
        rescue StandardError => e
          logger.debug { "[#{@role}] Failed to open monitoring connection: #{e.class}: #{e.message}" }
          @connection.set(nil)
          @panic_mode.make_true
          notify_changes
        end

        def map_merge(base, overrides)
          result = base.dup
          overrides.each { |k, v| result[k] = v }
          result
        end

        def iam_enabled?
          @service_container.plugin_manager.plugin_in_use?(Plugins::IamAuthPlugin)
        end

        def driver_dialect
          @service_container.dialect_service.driver_dialect
        end

        def clear_connection
          @connection.set(nil)
          @panic_mode.make_true
          notify_changes
        end

        def connection_closed?(conn)
          driver_dialect.closed?(conn)
        rescue StandardError
          true
        end

        def syntax_error?(err)
          driver_dialect.sql_state(err)&.start_with?('42') || false
        end

        def db_error?(err)
          !driver_dialect.sql_state(err).nil?
        end

        def status_available?(conn)
          dialect = @service_container.dialect_service.db_dialect
          return true if dialect.blue_green_status_available?(conn)

          if connection_closed?(conn)
            clear_connection
          else
            @current_phase = Phase::NOT_CREATED
            logger.debug { "[#{@role}] (status not available) current_phase: #{@current_phase}" }
          end
          false
        end

        def parse_status_entries(conn, dialect)
          driver_dialect.execute(conn, dialect.blue_green_status_query).each_with_object([]) do |row, entries|
            version = row['version']
            unless KNOWN_VERSIONS.include?(version)
              logger.warn do
                "[#{@role}] Blue/Green deployment uses version '#{version}' which the driver does not " \
                  "support. Version '#{LATEST_KNOWN_VERSION}' will be used instead."
              end
              version = LATEST_KNOWN_VERSION
            end

            role = Role.parse_role(row['role'], version)
            next if role != @role

            entries << StatusInfo.new(version, row['endpoint'], row['port'].to_i, Phase.parse_phase(row['status']), role)
          end
        end

        def resolve_status_info(status_entries)
          info = status_entries.find { |x| Utils::RdsUtils.writer_cluster_dns?(x.endpoint) && Utils::RdsUtils.not_old_instance?(x.endpoint) }
          @host_names.add(info.endpoint.downcase.gsub('.cluster-', '.cluster-ro-')) if info
          info || status_entries.find { |x| Utils::RdsUtils.rds_instance?(x.endpoint) && Utils::RdsUtils.not_old_instance?(x.endpoint) }
        end

        def apply_status_info(status_info, status_entries)
          if status_info.nil?
            if status_entries.empty?
              @current_phase = nil
              logger.debug { "[#{@role}] No entries in status table." } if @role != Role::SOURCE
            end
          else
            @current_phase = status_info.phase
            @version       = status_info.version
            @port          = status_info.port
          end

          return unless @collect_topology.true?

          @host_names.merge(
            status_entries.filter_map { |x| x.endpoint&.downcase if Utils::RdsUtils.not_old_instance?(x.endpoint) }
          )
        end

        # Compares the connected IP against the endpoint IP from the status table.
        # Reconnects to the correct host if a mismatch is detected.
        def verify_connection_host(status_info)
          return if @correct_connection_host.true? || status_info.nil?

          status_ip    = resolve_ip_address(status_info.endpoint)
          connected_ip = @connected_ip_address.get

          if connected_ip && connected_ip != status_ip
            @connection_host_info.set(@connection_host_info.get.deep_dup.tap do |h|
              h.host = status_info.endpoint
              h.port = status_info.port
            end)
            @correct_connection_host.make_true
            clear_connection
          else
            @correct_connection_host.make_true
            @panic_mode.make_false
          end
        end

        def handle_collect_status_error(err, conn)
          if syntax_error?(err)
            @current_phase = Phase::NOT_CREATED
            logger.warn { "[#{@role}] current_phase: #{@current_phase}, exception while querying for blue/green status." }
          elsif db_error?(err)
            if err.message.include?('An error occurred while retrieving the blue/green fast switchover metadata')
              @current_phase = Phase::NOT_CREATED
              return
            end
            logger.debug { "[#{@role}] Unhandled SQLException." }
            clear_connection unless connection_closed?(conn)
          else
            logger.debug { "[#{@role}] Unhandled exception." }
            clear_connection
          end
        end

        # Creates a scoped HostListProvider for this monitor using a unique cluster_id
        # to avoid interfering with the application's own provider.
        def init_host_list_provider
          return if @host_list_provider || @correct_connection_host.false?

          host_info = @connection_host_info.get
          return logger.warn { 'Unable to initialize HostListProvider since connection host information is null.' } if host_info.nil?

          cluster_id = "#{@bgd_id}::#{@role}::#{BG_CLUSTER}"
          logger.debug { "[#{@role}] Creating a new HostListProvider, cluster_id: #{cluster_id}." }

          scoped_wrapper_props = map_merge(@status_monitor_wrapper_props, PropertyDefinition::CLUSTER_ID.name => cluster_id)
          scoped_wrapper_props = map_merge(scoped_wrapper_props, PropertyDefinition::IAM_HOST.name => host_info.host) if iam_enabled?

          config = @service_container.connection_service.config.dup
          config.initial_host_info = host_info
          config.wrapper_props = scoped_wrapper_props

          scoped_connection_service = Services::ConnectionService.new(@service_container, config)
          scoped_container = Services::ServiceContainer.new(
            scoped_connection_service,
            @service_container.dialect_service,
            @service_container.event_publisher,
            @service_container.host_service,
            @service_container.plugin_manager,
            @service_container.session_state_service,
            @service_container.storage_service,
            @service_container.monitor_service
          )

          @host_list_provider = @service_container.dialect_service.db_dialect.create_host_list_provider(scoped_container)
        end
      end
    end
  end
end
