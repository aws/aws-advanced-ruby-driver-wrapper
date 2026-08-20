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
require 'timeout'
require_relative 'blue_green_test_helper'
require_relative 'blue_green_observer_threads'
require_relative 'capturing_logger'
require_relative 'driver_helper'
require_relative 'database_engine'
require_relative 'database_engine_deployment'
require_relative 'test_environment'

module Integration
  class BlueGreenSpecOrchestrator
    include BlueGreenObserverThreads

    # Timeout constants
    ORCHESTRATOR_TIMEOUT_SEC = 720   # 12 minutes — hard ceiling
    START_LATCH_TIMEOUT_SEC  = 300   # 5 minutes — max wait for threads to ready up
    FINISH_LATCH_TIMEOUT_SEC = 360   # 6 minutes — max wait for self-terminating threads
    POST_OBSERVATION_SEC     = 180   # 3 minutes — post-switchover observation window
    PRE_TRIGGER_DELAY_SEC    = 30    # 30 seconds — delay before triggering switchover
    THREAD_SHUTDOWN_SEC      = 5     # 5 seconds — grace period before force-kill

    LOGGER = Logger.new($stdout, progname: 'BlueGreenSpecOrchestrator')

    attr_reader :global_results, :instance_results, :combo_results, :capturing_logger

    def initialize(env:, driver:, rds_utility:, iam_enabled:, timeout: ORCHESTRATOR_TIMEOUT_SEC)
      @env = env
      @driver = driver
      @rds_utility = rds_utility
      @iam_enabled = iam_enabled
      @timeout = timeout

      @global_results = BlueGreenGlobalResults.new
      @instance_results = Concurrent::Hash.new
      @combo_results = Concurrent::Hash.new
      @threads = []
      @stop = Concurrent::AtomicBoolean.new(false)
      @finish_latch = nil
      @capturing_logger = nil
      @original_logger = nil
    end

    def run
      setup_capturing_logger

      Timeout.timeout(@timeout) do
        execute_orchestration
      end

      @global_results
    rescue Timeout::Error
      LOGGER.warn { 'Orchestrator hard timeout reached — collecting partial results' }
      @global_results.timed_out.make_true
      @global_results
    ensure
      shutdown_threads
      restore_logger
    end

    def force_shutdown
      shutdown_threads
      restore_logger
    end

    def blue_instances
      @instance_results.reject { |_id, r| rds_utils.green_instance?(r.host) || rds_utils.rds_cluster_dns?(r.host) }.keys
    end

    def green_instances
      @instance_results.select { |_id, r| rds_utils.green_instance?(r.host) }.keys
    end

    def bg_trigger_time
      @global_results.bg_trigger_time.get
    end

    def switchover_post_offset_ms
      # Max of SWITCHOVER_COMPLETED status time, green host change name time, and plugin-detected
      # completion time. On RDS instances, DirectTopology may die during switchover before seeing
      # SWITCHOVER_COMPLETED, so we fall back to the plugin's own POST/COMPLETED detection.
      completed_times = @instance_results.values.filter_map { |r| r.green_status_times['SWITCHOVER_COMPLETED'] }
      name_change_times = @instance_results.values.map { |r| r.green_host_change_name_time.get }.select(&:positive?)
      plugin_time = @global_results.switchover_post_nano_time.get
      raw_nanos = [completed_times.max || 0, name_change_times.max || 0, plugin_time].max
      time_offset_ms(raw_nanos)
    end

    def all_blue_dns_changed?
      blue_instances.all? { |id| @instance_results[id].dns_blue_changed_time.get.positive? }
    end

    def any_green_dns_removed?
      green_instances.any? { |id| @instance_results[id].dns_green_removed_time.get.positive? }
    end

    def all_direct_blue_lost_connection?
      blue_instances.all? { |id| @instance_results[id].direct_blue_lost_connection_time.get.positive? }
    end

    def successful_wrapper_connections_after(time_ms)
      combo_results_for('bg').sum do |r|
        r.wrapper_connect_times.count { |t| t.error.nil? && time_offset_ms(t.start_time) > time_ms }
      end
    end

    def successful_wrapper_executions_after_switchover
      combo_results_for('bg').sum do |r|
        r.wrapper_post_switchover_execute_times.count { |t| t.error.nil? }
      end
    end

    def time_offset_ms(nano_timestamp)
      return 0 if nano_timestamp.zero? || bg_trigger_time.zero?

      (nano_timestamp - bg_trigger_time) / 1_000_000
    end

    # Returns all PluginComboResults for a given combo (across all hosts)
    def combo_results_for(combo)
      @combo_results.select { |key, _| key.start_with?("#{combo}::") }.values
    end

    private

    def rds_utils
      AwsRubyDatabaseDriverWrapper::Utils::RdsUtils
    end

    def setup_capturing_logger
      @original_logger = AwsRubyDatabaseDriverWrapper.logger
      @capturing_logger = CapturingLogger.new(@original_logger)
      AwsRubyDatabaseDriverWrapper.logger = @capturing_logger
    end

    def restore_logger
      return unless @original_logger

      AwsRubyDatabaseDriverWrapper.logger = @original_logger
      @original_logger = nil
    end

    def shutdown_threads
      @stop.make_true

      # Wait for threads to exit gracefully via finish_latch (each thread counts down in ensure)
      if @finish_latch
        graceful = @finish_latch.wait(THREAD_SHUTDOWN_SEC)
        LOGGER.debug { "Graceful shutdown: #{graceful ? 'all threads exited' : 'some threads still running'}" }
      else
        sleep(THREAD_SHUTDOWN_SEC)
      end

      # Silently force-kill any stragglers — suppress thread abort exceptions
      @threads.each do |t|
        next unless t.alive?

        t.report_on_exception = false
        t.kill
      end
      sleep(0.5)
    end

    # Waits for the switchover to reach a terminal state (COMPLETED or rollback).
    # Polls the global results and captured log for signals that the switchover
    # has reached a terminal or post-switchover state.
    def wait_for_switchover_outcome
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + FINISH_LATCH_TIMEOUT_SEC

      until Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
        captured = @capturing_logger.captured_output.string

        # Switchover completed successfully — the plugin emitted the final summary
        if captured.include?('Blue/Green Deployment Switchover COMPLETED')
          @global_results.switchover_done.make_true
          @global_results.switchover_post_nano_time.compare_and_set(0, Process.clock_gettime(Process::CLOCK_MONOTONIC, :nanosecond))
          LOGGER.info { 'Switchover completed — proceeding to post-observation' }
          return
        end

        # Switchover rolled back — the plugin emitted the rollback summary
        if captured.include?('Blue/Green Deployment Switchover ROLLED BACK')
          LOGGER.info { 'Switchover rolled back — proceeding to post-observation' }
          return
        end

        # Rollback detected by our detection thread
        if @global_results.rollback?
          LOGGER.info { 'Rollback detected — proceeding to post-observation' }
          return
        end

        # POST phase reached and connections released — switchover functionally complete
        # even if the plugin hasn't finished DNS tracking for its internal COMPLETED state.
        # This handles cases where DNS propagation is slow in the test container.
        if captured.include?('switchover is completed. Continue with')
          @global_results.switchover_done.make_true
          @global_results.switchover_post_nano_time.compare_and_set(0, Process.clock_gettime(Process::CLOCK_MONOTONIC, :nanosecond))
          LOGGER.info { 'Switchover POST phase reached and connections released — proceeding to post-observation' }
          return
        end

        sleep(1)
      end

      LOGGER.warn { 'Switchover outcome wait timed out — proceeding anyway' }
    end

    def execute_orchestration
      bgd_id = @env.bg_deployment_id
      raise 'bg_deployment_id not found in test environment' if bgd_id.nil? || bgd_id.empty?

      endpoints = @rds_utility.get_blue_green_endpoints(
        bgd_id,
        deployment: @env.deployment,
        engine: @env.engine
      )
      LOGGER.info { "BG endpoints: #{endpoints.join(', ')}" }

      blue_hosts = endpoints.select { |h| rds_utils.not_green_and_old_prefix_instance?(h) }
      green_hosts = endpoints.select { |h| rds_utils.green_instance?(h) }

      LOGGER.info { "Blue hosts (#{blue_hosts.size}): #{blue_hosts.join(', ')}" }
      LOGGER.info { "Green hosts (#{green_hosts.size}): #{green_hosts.join(', ')}" }

      # Initialize per-instance results
      (blue_hosts + green_hosts).each do |host|
        host_id = host.split('.').first
        @instance_results[host_id] = BlueGreenInstanceResults.new(host_id: host_id, host: host)
      end

      # Count threads and create latches
      thread_count = count_threads(blue_hosts, green_hosts)
      start_latch = Concurrent::CountDownLatch.new(thread_count)
      @finish_latch = Concurrent::CountDownLatch.new(thread_count)

      # Create all threads
      create_blue_threads(blue_hosts, bgd_id, start_latch, @finish_latch)
      create_green_threads(green_hosts, bgd_id, start_latch, @finish_latch)
      create_control_threads(bgd_id, start_latch, @finish_latch)
      create_cluster_endpoint_thread(bgd_id, start_latch, @finish_latch) if aurora_deployment?

      # Threads created with Thread.new start immediately
      LOGGER.info { "All #{@threads.size} threads started (latch count: #{thread_count})" }

      # Wait for start latch
      latch_start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      unless start_latch.wait(START_LATCH_TIMEOUT_SEC)
        elapsed = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - latch_start).round(1)
        LOGGER.warn { "Start latch timed out after #{elapsed}s — some threads did not become ready" }
        # Diagnose which threads are still alive but haven't counted down
        stuck_threads = @threads.select(&:alive?).map { |t| t.name || 'unnamed' }
        dead_threads = @threads.reject(&:alive?).map { |t| t.name || 'unnamed' }
        LOGGER.warn { "Threads still alive (may be stuck connecting): #{stuck_threads.join(', ')}" }
        LOGGER.warn { "Threads already dead (may have crashed before counting down): #{dead_threads.join(', ')}" }
        LOGGER.warn do
          "Unhandled exceptions so far: #{@global_results.unhandled_exceptions.map do |e|
            "#{e.class}: #{e.message}"
          end.join('; ')}"
        end
      end

      # Wait for switchover to complete or rollback to be detected.
      # The RollbackDetection thread and self-terminating threads (BlueDNS, GreenDNS, etc.)
      # will count down the finish latch. Continuously-running threads (WrapperBlueExecute,
      # WrapperBlueNewConn, etc.) only stop when @stop is set.
      # We wait up to FINISH_LATCH_TIMEOUT_SEC for the key signals, then proceed.
      wait_for_switchover_outcome

      # Post-switchover observation — keep threads running to collect post-switchover data
      LOGGER.info { "Post-observation period: #{POST_OBSERVATION_SEC}s" }
      sleep(POST_OBSERVATION_SEC)
    end

    def count_threads(blue_hosts, green_hosts)
      count = 0
      # Per blue host: infrastructure threads
      #   DirectBlueConnectivity, BlueDNS, DirectTopology = 3
      count += blue_hosts.size * 3
      # Per blue host: combo threads
      plugin_combos.each do |combo|
        count += if combo.include?('failover')
                   blue_hosts.size * 1 # FailoverExecute
                 elsif aurora_deployment?
                   blue_hosts.size * 3 # Execute, NewConn, HostVerification
                 else
                   blue_hosts.size * 2 # Execute, NewConn (no HostVerification on RDS Multi-AZ)
                 end
      end
      # Per green host: connectivity + DNS
      count += green_hosts.size * 2
      # Control: switchover trigger + rollback detection + readiness
      count += 3
      # Cluster endpoint (Aurora only)
      count += 1 if aurora_deployment?
      count
    end

    def aurora_deployment?
      @env.deployment == DatabaseEngineDeployment::AURORA
    end

    def port
      @env.database_info.instance_endpoint_port || @env.writer.port
    end

    def db_config
      DriverHelper.native_config(
        @driver,
        host: nil, # overridden per thread
        port: port,
        user: @env.database_info.username,
        password: @env.database_info.password,
        dbname: @env.database_info.default_dbname
      )
    end

    def wrapper_dialect
      case @env.deployment
      when DatabaseEngineDeployment::AURORA
        @env.engine == DatabaseEngine::MYSQL ? 'aurora-mysql' : 'aurora-pg'
      when DatabaseEngineDeployment::RDS_MULTI_AZ_INSTANCE
        @env.engine == DatabaseEngine::MYSQL ? 'rds-mysql' : 'rds-pg'
      end
    end

    def wrapper_config_for(host, host_id, combo:)
      config = DriverHelper.native_config(
        @driver,
        host: host,
        port: port,
        user: @env.database_info.username,
        password: @env.database_info.password,
        dbname: @env.database_info.default_dbname
      )
      config[:wrapper_plugins] = combo
      config[:bgd_id] = @env.bg_deployment_id
      config[:cluster_id] = "#{combo.tr(',', '-')}-test-#{host_id}"
      config[:wrapper_dialect] = wrapper_dialect if wrapper_dialect
      config[:bg_switchover_timeout_ms] = 180_000
      config[:bg_connect_timeout_ms] = 60_000
      config[:connect_timeout] = 10
      config[:read_timeout] = 10 if @driver == TestDriver::MYSQL

      # IAM-specific props
      if combo.include?('iam')
        config[:iam_region] = @env.aurora_region
        user_key = @driver == TestDriver::MYSQL ? :username : :user
        config[user_key] = @env.iam_user_name
        config.delete(:password)
        # IAM auth requires SSL
        case @driver
        when TestDriver::PG then config[:sslmode] = 'require'
        when TestDriver::MYSQL then config[:ssl_mode] = :required
        end
      end

      # Failover-specific props
      if combo.include?('failover') && @env.database_info.instance_endpoint_suffix
        config[:cluster_instance_host_pattern] = "?.#{@env.database_info.instance_endpoint_suffix}:#{port}"
      end

      config
    end

    def plugin_combos
      if aurora_deployment?
        combos = ['bg', 'bg,failover']
        combos += ['bg,iam', 'bg,failover,iam'] if @iam_enabled
      else
        combos = ['bg']
        combos << 'bg,iam' if @iam_enabled
      end
      combos
    end

    def create_blue_threads(blue_hosts, _bgd_id, start_latch, finish_latch)
      blue_hosts.each do |host|
        host_id = host.split('.').first
        instance_result = @instance_results[host_id]
        native_config = db_config.merge(host: host)

        # --- Infrastructure threads (not per-combo, write to @instance_results) ---

        @threads << build_direct_blue_connectivity_thread(
          host_id: host_id, driver: @driver, config: native_config,
          start_latch: start_latch, stop: @stop, finish_latch: finish_latch,
          results: instance_result, global: @global_results
        )

        @threads << build_blue_dns_thread(
          host_id: host_id, host: host,
          start_latch: start_latch, stop: @stop, finish_latch: finish_latch,
          results: instance_result, global: @global_results
        )

        @threads << build_direct_topology_monitoring_thread(
          host_id: host_id, driver: @driver, config: native_config,
          engine: @env.engine, deployment: @env.deployment,
          start_latch: start_latch, stop: @stop, finish_latch: finish_latch,
          results: instance_result, global: @global_results
        )

        # --- Per-combo wrapper threads (write to @combo_results) ---

        plugin_combos.each do |combo|
          combo_config = wrapper_config_for(host, host_id, combo: combo)
          combo_label = combo.tr(',', '-')
          combo_result = PluginComboResults.new(combo: combo, host_id: host_id)
          @combo_results["#{combo}::#{host_id}"] = combo_result

          LOGGER.info { "Creating combo threads for '#{combo}' on #{host_id}" }

          if combo.include?('failover')
            @threads << build_wrapper_blue_failover_executing_thread(
              host_id: "#{combo_label}-#{host_id}", driver: @driver, config: combo_config,
              start_latch: start_latch, stop: @stop, finish_latch: finish_latch,
              global: @global_results, results: combo_result
            )
          else
            # Standard combo threads: Execute, NewConn, HostVerification (Aurora only)
            @threads << build_wrapper_blue_executing_thread(
              host_id: "#{combo_label}-#{host_id}", driver: @driver, config: combo_config,
              start_latch: start_latch, stop: @stop, finish_latch: finish_latch,
              results: combo_result, global: @global_results
            )

            @threads << build_wrapper_blue_new_connection_thread(
              host_id: "#{combo_label}-#{host_id}", driver: @driver, config: combo_config,
              start_latch: start_latch, stop: @stop, finish_latch: finish_latch,
              results: combo_result, global: @global_results
            )

            # Host verification requires server id. Skip on RDS Multi-AZ instances.
            if aurora_deployment?
              @threads << build_wrapper_blue_host_verification_thread(
                host_id: "#{combo_label}-#{host_id}", driver: @driver, config: combo_config,
                start_latch: start_latch, stop: @stop, finish_latch: finish_latch,
                results: combo_result, global: @global_results
              )
            end
          end
        end
      end
    end

    def create_green_threads(green_hosts, _bgd_id, start_latch, finish_latch)
      green_hosts.each do |host|
        host_id = host.split('.').first
        results = @instance_results[host_id]
        wrapper_config = wrapper_config_for(host, host_id, combo: 'bg')

        @threads << build_wrapper_green_connectivity_thread(
          host_id: host_id, driver: @driver, config: wrapper_config,
          start_latch: start_latch, stop: @stop, finish_latch: finish_latch,
          results: results, global: @global_results
        )

        @threads << build_green_dns_thread(
          host_id: host_id, host: host,
          start_latch: start_latch, stop: @stop, finish_latch: finish_latch,
          results: results, global: @global_results
        )
      end
    end

    def create_control_threads(bgd_id, start_latch, finish_latch)
      @threads << build_switchover_trigger_thread(
        bgd_id: bgd_id, rds_utility: @rds_utility,
        pre_trigger_delay: PRE_TRIGGER_DELAY_SEC,
        start_latch: start_latch, finish_latch: finish_latch,
        global: @global_results, instance_results: @instance_results
      )

      @threads << build_rollback_detection_thread(
        bgd_id: bgd_id,
        start_latch: start_latch, stop: @stop, finish_latch: finish_latch,
        global: @global_results
      )

      @threads << build_readiness_log_capture_thread(
        capturing_logger: @capturing_logger,
        start_latch: start_latch, stop: @stop, finish_latch: finish_latch,
        global: @global_results
      )
    end

    def create_cluster_endpoint_thread(_bgd_id, start_latch, finish_latch)
      cluster_endpoint = @env.database_info.cluster_endpoint
      return unless cluster_endpoint

      host_id = cluster_endpoint.split('.').first
      config = wrapper_config_for(cluster_endpoint, "cluster-#{host_id}", combo: 'bg')

      # Store cluster endpoint results in combo_results
      combo_result = PluginComboResults.new(combo: 'bg', host_id: "cluster-#{host_id}")
      @combo_results["bg::cluster-#{host_id}"] = combo_result

      @threads << build_wrapper_blue_new_connection_thread(
        host_id: "cluster-#{host_id}", driver: @driver, config: config,
        start_latch: start_latch, stop: @stop, finish_latch: finish_latch,
        results: combo_result, global: @global_results
      )
    end
  end
end
