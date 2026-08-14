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
require_relative '../../property_definition'
require_relative '../../utils/rds_utils'
require_relative 'iam_host_tracker'
require_relative 'interval_rate'
require_relative 'host_mapper'
require_relative 'phase'
require_relative 'phase_event_log'
require_relative 'phase_time_info'
require_relative 'role'
require_relative 'status'
require_relative 'status_builder'
require_relative 'status_monitor'
require_relative 'switchover_state'
require_relative 'switchover_timer'
require_relative '../../plugins/iam_auth_plugin'

module AwsRubyDatabaseDriverWrapper
  module Plugins
    module BlueGreen
      class StatusProvider
        include Logging

        DEFAULT_CONNECT_TIMEOUT_SEC = 10
        DEFAULT_SOCKET_TIMEOUT_SEC  = 10

        def initialize(service_container, wrapper_props, bgd_id, cluster_id)
          @service_container = service_container
          @storage_service   = service_container.storage_service
          @wrapper_props     = wrapper_props
          @bgd_id            = bgd_id
          @cluster_id        = cluster_id

          @monitoring_wrapper_props = build_monitoring_wrapper_props
          @monitoring_driver_props = build_monitoring_driver_props

          @monitors              = { Role::SOURCE => nil, Role::TARGET => nil }
          @interim_statuses      = { Role::SOURCE => nil, Role::TARGET => nil }
          @interim_status_hashes = { Role::SOURCE => 0,   Role::TARGET => 0 }
          @last_context_hash     = 0
          @summary_status        = nil
          @latest_status_phase   = Phase::NOT_CREATED
          @rollback              = false
          @process_status_lock   = Mutex.new
          @monitor_generation    = 0

          @status_check_interval_map = {
            IntervalRate::BASELINE => PropertyDefinition::BG_INTERVAL_BASELINE_MS.get(wrapper_props),
            IntervalRate::INCREASED => PropertyDefinition::BG_INTERVAL_INCREASED_MS.get(wrapper_props),
            IntervalRate::HIGH => PropertyDefinition::BG_INTERVAL_HIGH_MS.get(wrapper_props)
          }

          @green_topology_recognized_logged = false

          @timer           = SwitchoverTimer.new(PropertyDefinition::BG_SWITCHOVER_TIMEOUT_MS.get(wrapper_props) * 1_000_000)
          @event_log       = PhaseEventLog.new
          @host_mapper     = HostMapper.new
          @iam_tracker     = IamHostTracker.new(on_all_changed: method(:on_all_green_hosts_changed))
          @switchover_state = SwitchoverState.new(
            on_monitor_reset: method(:publish_monitor_reset),
            on_event: method(:record_event)
          )
          @builder = StatusBuilder.new(@bgd_id, @host_mapper, @timer, @interim_statuses, @iam_tracker, @switchover_state)

          dialect = service_container.dialect_service.db_dialect
          if dialect.respond_to?(:blue_green_status_available?)
            init_monitoring
          else
            logger.warn { "[bgd_id: '#{@bgd_id}'] Blue/Green Deployments isn't supported by database dialect #{dialect.class.name}." }
          end
        end

        def stop
          @monitors.each_value { |m| m&.stop }
        end

        def log_switchover_final_summary
          return unless switchover_finalized?

          logger.info(@event_log.summary(@bgd_id, @rollback))
        end

        def log_current_context
          phase_str = @summary_status&.current_phase&.to_s || '<null>'
          logger.debug { "[bgd_id: '#{@bgd_id}'] BG status: #{phase_str}" }
          logger.debug { "[bgd_id: '#{@bgd_id}'] Summary status:\n#{@summary_status || '<null>'}" }
          logger.debug { "Corresponding hosts:\n#{@host_mapper.to_debug_s}" }
          logger.debug { "Phase times:\n#{@event_log.to_debug_s}" }
          logger.debug { "Green host certificate change times:\n#{@iam_tracker.to_debug_s}" }
          logger.debug { "\n   latest_status_phase: #{@latest_status_phase}\n#{@switchover_state.to_debug_s(@iam_tracker)}" }
        end

        def log_green_topology_recognized
          return if @green_topology_recognized_logged
          return unless green_topology_ready?

          @green_topology_recognized_logged = true

          source_status = @interim_statuses[Role::SOURCE]
          target_status = @interim_statuses[Role::TARGET]
          source_host_count = source_status.host_names.size
          target_host_count = target_status.host_names.size
          corresponding_host_count = @host_mapper.corresponding_hosts.count { |_, v| v[1] }

          mapping_str = format_host_mapping
          ip_str = format_ip_mapping

          logger.info do
            "[bgd_id: '#{@bgd_id}'] Blue/Green target topology recognized\n   " \
              "phase: #{@latest_status_phase}\n   " \
              "source_hosts: #{source_host_count}\n   " \
              "target_hosts: #{target_host_count}\n   " \
              "corresponding_hosts: #{corresponding_host_count}\n   " \
              "ready: true\n " \
              "Blue -> Green Mapping:\n   " \
              "#{mapping_str}\n " \
              "Host -> IP Mapping:\n   " \
              "#{ip_str}"
          end
        end

        def green_topology_ready?
          source_status = @interim_statuses[Role::SOURCE]
          target_status = @interim_statuses[Role::TARGET]

          source_status &&
            target_status &&
            source_status.start_topology&.any? &&
            target_status.start_topology&.any? &&
            source_status.host_names&.any? &&
            target_status.host_names&.any? &&
            @host_mapper.corresponding_hosts.any?
        end

        def format_host_mapping
          rows = @host_mapper.corresponding_hosts.sort_by { |k, _| k }.map do |blue, pair|
            "#{blue} -> #{pair[1]&.host_and_port || '<null>'}"
          end
          rows.any? ? rows.join("\n   ") : '-'
        end

        def format_ip_mapping
          rows = @host_mapper.host_ip_addresses.sort_by { |k, _| k }.map do |host, ip|
            "#{host} -> #{ip || '<null>'}"
          end
          rows.any? ? rows.join("\n   ") : '-'
        end

        def check_switchover_timer_expiry
          return unless @timer.expired?
          return unless [Phase::IN_PROGRESS, Phase::POST, Phase::PREPARATION].include?(@latest_status_phase)

          logger.warn { 'Blue/Green switchover has timed out.' }
          @summary_status = @rollback ? @builder.created : @builder.completed(@rollback)
          update_monitors
          update_status_cache
          log_current_context
        end

        def reset_context_when_completed
          return unless switchover_finalized?

          logger.debug { 'Resetting context.' }

          old_monitors = @monitors
          @monitor_generation += 1
          @monitors = { Role::SOURCE => nil, Role::TARGET => nil }
          old_monitors.each_value { |m| m&.stop }

          Plugins::IamAuthPlugin.clear_cache(@storage_service) if iam_enabled?
          @storage_service.remove(Host::RdsHostListProvider::TOPOLOGY_CACHE_NAME, @cluster_id)

          @rollback = false
          @green_topology_recognized_logged = false
          @summary_status        = nil
          @latest_status_phase   = Phase::NOT_CREATED
          @interim_status_hashes = { Role::SOURCE => 0, Role::TARGET => 0 }
          @last_context_hash     = 0
          @interim_statuses      = { Role::SOURCE => nil, Role::TARGET => nil }

          @timer.reset
          @event_log.clear
          @host_mapper.clear
          @iam_tracker.clear
          @switchover_state.reset
          @builder = StatusBuilder.new(@bgd_id, @host_mapper, @timer, @interim_statuses, @iam_tracker, @switchover_state)

          init_monitoring
        end

        def update_summary_status(role, interim_status)
          case @latest_status_phase
          when Phase::NOT_CREATED then @summary_status = Status.new(@bgd_id, Phase::NOT_CREATED)
          when Phase::CREATED
            @switchover_state.update_dns_flags(@bgd_id, role, interim_status)
            @summary_status = @builder.created
          when Phase::PREPARATION
            @timer.start
            @switchover_state.update_dns_flags(@bgd_id, role, interim_status)
            @summary_status = @builder.preparation(@rollback)
          when Phase::IN_PROGRESS
            @switchover_state.update_dns_flags(@bgd_id, role, interim_status)
            @summary_status = @builder.in_progress(@rollback)
            @switchover_state.trigger_in_progress_monitor_reset
          when Phase::POST
            @switchover_state.update_dns_flags(@bgd_id, role, interim_status)
            @summary_status = @builder.post(@rollback)
          when Phase::COMPLETED
            @switchover_state.update_dns_flags(@bgd_id, role, interim_status)
            @summary_status = @builder.completed(@rollback)
          else
            raise ArgumentError, "[bgd_id: '#{@bgd_id}'] Unknown BG phase '#{@latest_status_phase}'."
          end
        end

        MONITOR_SETTINGS = {
          Phase::NOT_CREATED => { interval: IntervalRate::BASELINE, collect_ips: false, collect_topo: false, use_ip: false }.freeze,
          Phase::CREATED => { interval: IntervalRate::INCREASED, collect_ips: true, collect_topo: true, use_ip: false }.freeze,
          Phase::PREPARATION => { interval: IntervalRate::HIGH,      collect_ips: false, collect_topo: false, use_ip: true  }.freeze,
          Phase::IN_PROGRESS => { interval: IntervalRate::HIGH,      collect_ips: false, collect_topo: false, use_ip: true  }.freeze,
          Phase::POST => { interval: IntervalRate::HIGH, collect_ips: false, collect_topo: false, use_ip: true }.freeze,
          Phase::COMPLETED => { interval: IntervalRate::BASELINE, collect_ips: false, collect_topo: false, use_ip: false }.freeze
        }.freeze

        def update_monitors
          settings = MONITOR_SETTINGS.fetch(@summary_status.current_phase) do
            raise ArgumentError, "[bgd_id: '#{@bgd_id}'] Unknown BG phase '#{@summary_status.current_phase}'."
          end

          @monitors.values.compact.each do |monitor|
            monitor.interval_rate = settings[:interval]
            monitor.collect_ip_addresses = settings[:collect_ips]
            monitor.collect_topology     = settings[:collect_topo]
            monitor.use_ip_address       = settings[:use_ip]
            monitor.reset_collected_data if (@rollback && @summary_status.current_phase == Phase::CREATED) ||
                                            @summary_status.current_phase == Phase::COMPLETED
          end
        end

        def update_status_cache
          latest_status = @storage_service.get(BlueGreenPlugin::BLUE_GREEN_NAME, @bgd_id)
          @storage_service.set(BlueGreenPlugin::BLUE_GREEN_NAME, @bgd_id, @summary_status)
          store_phase_time(@summary_status.current_phase)
          latest_status&.notify
        end

        def update_phase(role, interim_status)
          new_phase            = interim_status.blue_green_phase
          latest_interim_phase = @interim_statuses[role]&.blue_green_phase || Phase::NOT_CREATED

          if role == Role::TARGET &&
             !new_phase.nil? &&
             @latest_status_phase != Phase::COMPLETED &&
             new_phase < latest_interim_phase
            @rollback = true
            logger.debug { "[bgd_id: '#{@bgd_id}'] Blue/Green deployment is in rollback mode." }
          end

          return if new_phase.nil?

          if @rollback
            @latest_status_phase = new_phase if new_phase < @latest_status_phase
          elsif new_phase > @latest_status_phase
            @latest_status_phase = new_phase
          end
        end

        def prepare_status(role, interim_status, generation = @monitor_generation)
          @process_status_lock.synchronize do
            return if generation != @monitor_generation

            status_hash = interim_status.hash
            ctx_hash    = context_hash

            if @interim_status_hashes[role] == status_hash && @last_context_hash == ctx_hash
              check_switchover_timer_expiry
              return
            end

            logger.debug { "[bgd_id: '#{@bgd_id}', role: #{role}] #{interim_status}" }

            update_phase(role, interim_status)

            @interim_statuses[role]      = interim_status
            @interim_status_hashes[role] = status_hash
            @last_context_hash           = ctx_hash

            @host_mapper.merge_ips(interim_status.start_ip_addresses_by_host)
            @host_mapper.register_role(interim_status.host_names, role)
            @host_mapper.update(@interim_statuses[Role::SOURCE], @interim_statuses[Role::TARGET])

            update_summary_status(role, interim_status)
            check_switchover_timer_expiry
            update_monitors
            update_status_cache
            log_current_context
            log_green_topology_recognized
            log_switchover_final_summary
            reset_context_when_completed
          end
        end

        private

        def record_event(label, phase: nil)
          @event_log.record(label, @rollback ? ' (rollback)' : '', phase: phase)
        end

        def store_phase_time(phase)
          return if phase.nil?

          record_event(phase.to_s, phase: phase)
        end

        def on_all_green_hosts_changed
          record_event('Green host certificates changed')
        end

        def publish_monitor_reset(_event_name)
          blue_endpoints = @summary_status.role_by_host
                                          .select { |_host, role| role == Role::SOURCE }
                                          .keys
                                          .to_set

          @service_container.event_publisher.publish(
            Utils::Events::MonitorResetEvent.new(cluster_id: @cluster_id, endpoints: blue_endpoints)
          )
        end

        def switchover_finalized?
          completed = (!@rollback && @summary_status.current_phase == Phase::COMPLETED) ||
                      (@rollback && @summary_status.current_phase == Phase::CREATED)
          completed && @event_log.any? { |_, v| v.phase&.active_switchover_or_completed? }
        end

        def iam_enabled?
          @service_container.plugin_manager&.plugin_in_use?(Plugins::IamAuthPlugin) || false
        end

        def context_hash
          [@iam_tracker.all_changed?, @iam_tracker.size].hash
        end

        def init_monitoring
          generation = @monitor_generation
          [Role::SOURCE, Role::TARGET].each do |role|
            monitor = StatusMonitor.new(
              role,
              @bgd_id,
              @service_container.connection_service.current_host_info,
              @service_container,
              monitoring_driver_props: @monitoring_driver_props,
              status_check_interval_map: @status_check_interval_map,
              on_change_func: ->(r, s) { prepare_status(r, s, generation) },
              monitoring_wrapper_props: @monitoring_wrapper_props
            )
            @monitors[role] = monitor
            monitor.start
          end
        end

        # Wrapper overrides are merged onto base wrapper_props with defaults applied.
        # @return Hash monitoring_wrapper_props
        def build_monitoring_wrapper_props
          prefixed_wrapper_config = @service_container.connection_service.prefixed_wrapper_config[PropertyDefinition::BG_MONITORING_PROPERTY_PREFIX] || {}
          monitoring_wrapper_props = @wrapper_props.dup

          prefixed_wrapper_config.each do |key, value|
            monitoring_wrapper_props[key] = value
          end

          # Ensure BG monitoring connections bypass BG routing.
          monitoring_wrapper_props[BlueGreenPlugin::BG_SKIP_ROUTING_KEY] = true

          monitoring_wrapper_props
        end

        # Driver overrides are merged onto base driver_props with defaults applied.
        # @return Hash monitoring_driver_props
        def build_monitoring_driver_props
          prefixed_driver_props = @service_container.connection_service.prefixed_driver_config[PropertyDefinition::BG_MONITORING_PROPERTY_PREFIX] || {}
          monitoring_driver_props = @service_container.connection_service.driver_props.dup

          prefixed_driver_props.each do |key, value|
            monitoring_driver_props[key] = value
          end

          monitoring_driver_props[:connect_timeout] ||= DEFAULT_CONNECT_TIMEOUT_SEC
          monitoring_driver_props[:read_timeout]    ||= DEFAULT_SOCKET_TIMEOUT_SEC unless @service_container.connection_service.pg?

          monitoring_driver_props
        end
      end
    end
  end
end
