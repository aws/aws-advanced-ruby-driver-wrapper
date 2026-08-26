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
require_relative 'blue_green_test_helper'
require_relative 'driver_helper'
require_relative 'database_engine'

module Integration
  # Thread-factory methods for Blue/Green Deployment integration tests.
  # Each method returns a Thread that monitors one concern during switchover.
  module BlueGreenObserverThreads
    module_function

    LOGGER = Logger.new($stdout, progname: 'BlueGreenObserverThreads')

    def open_direct_connection_with_retry(driver, config, max_retries: 10)
      retries = 0
      loop do
        return DriverHelper.native_connect(driver, **config)
      rescue StandardError => e
        retries += 1
        raise e if retries >= max_retries

        sleep(1)
      end
    end

    def open_wrapper_with_retry(driver, config, max_retries: 10)
      retries = 0
      loop do
        return DriverHelper.wrapper_connect(driver, **config)
      rescue StandardError => e
        retries += 1
        LOGGER.debug { "open_wrapper_with_retry: attempt #{retries}/#{max_retries} failed — #{e.class}: #{e.message}" } if retries >= 3
        raise e if retries >= max_retries

        sleep(1)
      end
    end

    def safe_close(driver, conn)
      return if conn.nil?

      DriverHelper.close(driver, conn)
    rescue StandardError
      # ignore
    end

    def query_server_identity(driver, conn)
      sql = case driver
            when TestDriver::MYSQL then 'SELECT @@aurora_server_id'
            when TestDriver::PG then 'SELECT inet_server_addr()::text'
            else raise "Unsupported driver: #{driver}"
            end
      result = DriverHelper.execute(driver, conn, sql)
      row = result.first
      return nil if row.nil?

      row.values.first&.to_s
    end

    def nano_time
      Process.clock_gettime(Process::CLOCK_MONOTONIC, :nanosecond)
    end

    def build_direct_blue_connectivity_thread(host_id:, driver:, config:, start_latch:, stop:, finish_latch:, results:, global:)
      Thread.new do
        Thread.current.name = "DirectBlueConnectivity@#{host_id}"
        conn = nil
        begin
          begin
            conn = open_direct_connection_with_retry(driver, config)
          rescue StandardError => e
            LOGGER.warn { "[DirectBlueConnectivity@#{host_id}] Initial connection failed: #{e.class}: #{e.message}" }
            start_latch.count_down
            raise e
          end
          sleep(1)
          start_latch.count_down
          start_latch.wait(300)

          until stop.true?
            begin
              DriverHelper.execute(driver, conn, 'SELECT 1')
              sleep(1)
            rescue StandardError => e
              LOGGER.debug { "[DirectBlueConnectivity@#{host_id}] exception: #{e.message}" }
              results.record_timestamp(results.direct_blue_lost_connection_time)
              break
            end
          end
        rescue StandardError => e
          global.unhandled_exceptions << e
        ensure
          safe_close(driver, conn)
          finish_latch.count_down
        end
      end
    end

    def build_wrapper_blue_executing_thread(host_id:, driver:, config:, start_latch:, stop:, finish_latch:, results:, global:)
      Thread.new do
        Thread.current.name = "WrapperBlueExecute@#{host_id}"
        conn = nil
        begin
          sleep_sql = case driver
                      when TestDriver::MYSQL then 'SELECT SLEEP(5)'
                      when TestDriver::PG then 'SELECT pg_catalog.pg_sleep(5)'
                      end

          begin
            conn = open_wrapper_with_retry(driver, config)
          rescue StandardError => e
            LOGGER.warn { "[WrapperBlueExecute@#{host_id}] Initial connection failed: #{e.class}: #{e.message}" }
            start_latch.count_down
            raise e
          end
          sleep(1)
          start_latch.count_down
          start_latch.wait(300)

          # Phase 1: Execute until connection closes during switchover
          loop do
            break if stop.true?
            break if global.switchover_done? || global.rollback?

            start_t = nano_time
            begin
              DriverHelper.execute(driver, conn, sleep_sql)
              end_t = nano_time
              results.wrapper_pre_switchover_execute_times << TimeHolder.new(start_time: start_t, end_time: end_t)
            rescue StandardError => e
              end_t = nano_time
              results.wrapper_pre_switchover_execute_times << TimeHolder.new(start_time: start_t, end_time: end_t, error: e.message)
              closed = case driver
                       when TestDriver::PG then conn.finished?
                       when TestDriver::MYSQL then conn.closed?
                       end
              break if closed
            end
            sleep(1)
          end

          # Phase 2: Post-switchover — reconnect and continue.
          safe_close(driver, conn)
          conn = nil

          until stop.true?
            begin
              if conn.nil? || (driver == TestDriver::PG ? conn.finished? : conn.closed?)
                conn = DriverHelper.wrapper_connect(driver, **config)
              end
              start_t = nano_time
              DriverHelper.execute(driver, conn, sleep_sql)
              end_t = nano_time
              results.wrapper_post_switchover_execute_times << TimeHolder.new(start_time: start_t, end_time: end_t)
            rescue StandardError => e
              end_t = nano_time
              results.wrapper_post_switchover_execute_times << TimeHolder.new(start_time: start_t, end_time: end_t || nano_time,
                                                                              error: e.message)
              safe_close(driver, conn)
              conn = nil
            end
            sleep(1)
          end
        rescue StandardError => e
          global.unhandled_exceptions << e
        ensure
          safe_close(driver, conn)
          finish_latch.count_down
        end
      end
    end

    # Wrapper blue new connection: open/close loop, records connect time.
    def build_wrapper_blue_new_connection_thread(host_id:, driver:, config:, start_latch:, stop:, finish_latch:, results:, global:)
      Thread.new do
        Thread.current.name = "WrapperBlueNewConn@#{host_id}"
        conn = nil
        begin
          sleep(1)
          start_latch.count_down
          start_latch.wait(300)

          until stop.true?
            start_t = nano_time
            begin
              conn = DriverHelper.wrapper_connect(driver, **config)
              end_t = nano_time
              results.wrapper_connect_times << TimeHolder.new(start_time: start_t, end_time: end_t)
            rescue StandardError => e
              end_t = nano_time
              results.wrapper_connect_times << TimeHolder.new(start_time: start_t, end_time: end_t, error: e.message)
            end
            safe_close(driver, conn)
            conn = nil
            sleep(1)
          end
        rescue StandardError => e
          global.unhandled_exceptions << e
        ensure
          safe_close(driver, conn)
          finish_latch.count_down
        end
      end
    end

    # Wrapper blue host verification: connect, query server identity, compare to original.
    def build_wrapper_blue_host_verification_thread(host_id:, driver:, config:, start_latch:, stop:, finish_latch:, results:, global:)
      Thread.new do
        Thread.current.name = "WrapperBlueHostVerify@#{host_id}"
        conn = nil
        original_identity = nil
        begin
          # Get original blue identity
          begin
            conn = DriverHelper.wrapper_connect(driver, **config)
            original_identity = query_server_identity(driver, conn)
            safe_close(driver, conn)
            conn = nil
          rescue StandardError => e
            LOGGER.warn { "[WrapperBlueHostVerify@#{host_id}] Initial connection failed: #{e.class}: #{e.message}" }
            safe_close(driver, conn)
            conn = nil
            start_latch.count_down
            raise "Failed to get original blue identity for #{host_id}: #{e.message}"
          end

          raise "Failed to get original blue identity for #{host_id}" if original_identity.nil?

          sleep(1)
          start_latch.count_down
          start_latch.wait(300)

          until stop.true?
            begin
              conn = DriverHelper.wrapper_connect(driver, **config)
              connected_identity = query_server_identity(driver, conn)
              timestamp = nano_time
              connected_to_blue = (connected_identity == original_identity)
              results.host_verification_results << HostVerificationResult.new(
                timestamp: timestamp,
                connected_host: connected_identity,
                original_blue_ip: original_identity,
                connected_to_blue: connected_to_blue,
                error: nil
              )
            rescue StandardError => e
              timestamp = nano_time
              results.host_verification_results << HostVerificationResult.new(
                timestamp: timestamp,
                connected_host: nil,
                original_blue_ip: original_identity,
                connected_to_blue: false,
                error: e.message
              )
            end
            safe_close(driver, conn)
            conn = nil
            sleep(1)
          end
        rescue StandardError => e
          global.unhandled_exceptions << e
        ensure
          safe_close(driver, conn)
          finish_latch.count_down
        end
      end
    end

    # Blue DNS monitoring: polls Resolv.getaddress, records when IP changes.
    def build_blue_dns_thread(host_id:, host:, start_latch:, stop:, finish_latch:, results:, global:)
      Thread.new do
        Thread.current.name = "BlueDNS@#{host_id}"
        begin
          start_latch.count_down
          start_latch.wait(300)

          original_ip = Resolv.getaddress(host)
          LOGGER.debug { "[BlueDNS@#{host_id}] #{host} -> #{original_ip}" }

          until stop.true?
            sleep(1)
            begin
              current_ip = Resolv.getaddress(host)
              if current_ip != original_ip
                results.record_timestamp(results.dns_blue_changed_time)
                LOGGER.debug { "[BlueDNS@#{host_id}] IP changed: #{original_ip} -> #{current_ip}" }
                break
              end
            rescue Resolv::ResolvError => e
              results.record_timestamp(results.dns_blue_changed_time)
              LOGGER.debug { "[BlueDNS@#{host_id}] DNS error: #{e.message}" }
              break
            end
          end
        rescue StandardError => e
          global.unhandled_exceptions << e
        ensure
          finish_latch.count_down
        end
      end
    end

    # Direct topology monitoring: queries BG status table, records phase transitions.
    def build_direct_topology_monitoring_thread(host_id:, driver:, config:, engine:, deployment:, start_latch:, stop:, finish_latch:,
                                                results:, global:)
      Thread.new do
        Thread.current.name = "DirectTopology@#{host_id}"
        conn = nil
        begin
          query = topology_status_query(engine, deployment)
          conn = open_direct_connection_with_retry(driver, config)
          sleep(1)
          start_latch.count_down
          start_latch.wait(300)

          deadline = nano_time + (15 * 60 * 1_000_000_000) # 15 minutes

          until stop.true? || nano_time > deadline
            break if global.switchover_done? || global.rollback?

            conn = open_direct_connection_with_retry(driver, config) if conn.nil?

            begin
              rows = DriverHelper.execute(driver, conn, query)
              rows.each do |row|
                role_val = row_value(row, 'role')
                version_val = row_value(row, 'version')
                status_val = row_value(row, 'status')
                is_green = AwsAdvancedRubyDriverWrapper::Plugins::BlueGreen::Role.parse_role(role_val, version_val) ==
                           AwsAdvancedRubyDriverWrapper::Plugins::BlueGreen::Role::TARGET

                status_map = is_green ? results.green_status_times : results.blue_status_times
                status_map.compute_if_absent(status_val) do
                  LOGGER.debug { "[DirectTopology@#{host_id}] status: #{status_val} (green=#{is_green})" }
                  nano_time
                end
              end
              sleep(0.1)
            rescue StandardError => e
              LOGGER.debug { "[DirectTopology@#{host_id}] exception: #{e.message}" }
              safe_close(driver, conn)
              conn = nil
            end
          end
        rescue StandardError => e
          global.unhandled_exceptions << e
        ensure
          safe_close(driver, conn)
          finish_latch.count_down
        end
      end
    end

    # Wrapper green connectivity: wrapper SELECT 1 loop, records timing.
    def build_wrapper_green_connectivity_thread(host_id:, driver:, config:, start_latch:, stop:, finish_latch:, results:, global:)
      Thread.new do
        Thread.current.name = "WrapperGreenConn@#{host_id}"
        conn = nil
        begin
          conn = open_wrapper_with_retry(driver, config)
          sleep(1)
          start_latch.count_down
          start_latch.wait(300)

          until stop.true?
            start_t = nano_time
            begin
              DriverHelper.execute(driver, conn, 'SELECT 1')
              end_t = nano_time
              results.green_wrapper_execute_times << TimeHolder.new(start_time: start_t, end_time: end_t)
            rescue StandardError => e
              end_t = nano_time
              results.green_wrapper_execute_times << TimeHolder.new(start_time: start_t, end_time: end_t, error: e.message)
              results.record_timestamp(results.wrapper_green_lost_connection_time)
              break
            end
            sleep(1)
          end
        rescue StandardError => e
          global.unhandled_exceptions << e
        ensure
          safe_close(driver, conn)
          finish_latch.count_down
        end
      end
    end

    # Green DNS monitoring: polls Resolv.getaddress, records when DNS is removed.
    def build_green_dns_thread(host_id:, host:, start_latch:, stop:, finish_latch:, results:, global:)
      Thread.new do
        Thread.current.name = "GreenDNS@#{host_id}"
        begin
          start_latch.count_down
          start_latch.wait(300)

          begin
            ip = Resolv.getaddress(host)
            LOGGER.debug { "[GreenDNS@#{host_id}] #{host} -> #{ip}" }
          rescue Resolv::ResolvError
            # Already gone
            results.record_timestamp(results.dns_green_removed_time)
            return
          end

          until stop.true?
            sleep(1)
            begin
              Resolv.getaddress(host)
            rescue Resolv::ResolvError
              results.record_timestamp(results.dns_green_removed_time)
              LOGGER.debug { "[GreenDNS@#{host_id}] DNS removed" }
              break
            end
          end
        rescue StandardError => e
          global.unhandled_exceptions << e
        ensure
          finish_latch.count_down
        end
      end
    end

    # Switchover trigger: waits, then triggers the BG switchover via RDS API.
    def build_switchover_trigger_thread(bgd_id:, rds_utility:, pre_trigger_delay:, start_latch:, finish_latch:, global:, instance_results:)
      Thread.new do
        Thread.current.name = 'SwitchoverTrigger'
        begin
          start_latch.count_down
          start_latch.wait(300)

          sleep(pre_trigger_delay)
          rds_utility.switchover_blue_green_deployment(bgd_id)

          trigger_time = nano_time
          global.bg_trigger_time.set(trigger_time)
          LOGGER.info { "[SwitchoverTrigger] Switchover triggered at #{trigger_time}" }
        rescue StandardError => e
          global.unhandled_exceptions << e
        ensure
          finish_latch.count_down
        end
      end
    end

    # Rollback detection: polls storage service for phase regression.
    def build_rollback_detection_thread(bgd_id:, start_latch:, stop:, finish_latch:, global:)
      Thread.new do
        Thread.current.name = 'RollbackDetection'
        begin
          storage_service = AwsAdvancedRubyDriverWrapper::Services::CoreServices.storage_service
          start_latch.count_down
          start_latch.wait(300)

          highest_phase_value = 0

          until stop.true?
            begin
              status = storage_service.get(
                AwsAdvancedRubyDriverWrapper::Plugins::BlueGreen::BlueGreenPlugin::BLUE_GREEN_NAME,
                bgd_id
              )
            rescue ArgumentError
              # Cache not registered yet — BG plugin hasn't initialized. Wait and retry.
              sleep(1)
              next
            end

            if status&.current_phase
              current_value = status.current_phase.value

              # Once the phase reaches COMPLETED (value=5), the switchover succeeded.
              # After COMPLETED, the context resets (clearing the status table back to NOT_CREATED).
              # This is expected behavior, not a rollback. Stop monitoring.
              if highest_phase_value >= 5 # COMPLETED = 5
                LOGGER.debug { '[RollbackDetection] Switchover completed successfully — stopping rollback detection' }
                break
              end

              # After POST (value=4), a regression to NOT_CREATED (value=0) means the plugin
              # completed and reset its context. This happens when the COMPLETED phase is very
              # brief (status goes 4→5→0 between polls). Not a rollback.
              if current_value.zero? && highest_phase_value >= 4 # POST = 4
                LOGGER.debug { '[RollbackDetection] Phase reset to NOT_CREATED after POST — treating as successful completion' }
                global.switchover_done.make_true
                break
              end

              # Also check if the orchestrator already detected completion via log capture
              if global.switchover_done?
                LOGGER.debug { '[RollbackDetection] Orchestrator detected completion — stopping rollback detection' }
                break
              end

              # Detect rollback: phase regressed after reaching PREPARATION or higher
              # but before reaching COMPLETED or POST.
              if current_value < highest_phase_value && highest_phase_value >= 2 # PREPARATION = 2
                global.rollback.make_true
                global.rollback_final_phase.set(status.current_phase.to_s)
                LOGGER.warn { "[RollbackDetection] Rollback detected: phase regressed to #{status.current_phase}" }
                break
              end

              highest_phase_value = current_value if current_value > highest_phase_value
            end

            sleep(0.1)
          end
        rescue StandardError => e
          global.unhandled_exceptions << e
        ensure
          finish_latch.count_down
        end
      end
    end

    # Readiness log capture: subscribes to logger, watches for BG readiness message.
    def build_readiness_log_capture_thread(capturing_logger:, start_latch:, stop:, finish_latch:, global:)
      Thread.new do
        Thread.current.name = 'ReadinessCapture'
        detected = false
        subscriber = lambda do |_severity, message|
          next if detected

          if message.include?('Blue/Green target topology recognized') && message.include?('ready: true')
            detected = true
            global.green_topology_recognized_logged.make_true
            global.green_topology_recognized_time.set(nano_time)
          end
        end

        begin
          capturing_logger.add_subscriber(subscriber)
          start_latch.count_down
          start_latch.wait(300)

          sleep(0.5) until stop.true? || detected
        rescue StandardError => e
          global.unhandled_exceptions << e
        ensure
          capturing_logger.remove_subscriber(subscriber)
          finish_latch.count_down
        end
      end
    end

    # Reconnects a wrapper connection if the current one is nil or closed.
    # Returns the existing connection if still alive, or a new connection otherwise.
    def reconnect_if_needed(driver, conn, config)
      return conn unless conn.nil? || (driver == TestDriver::PG ? conn.finished? : conn.closed?)

      DriverHelper.wrapper_connect(driver, **config)
    end

    # bg,failover executing thread: queries with bg,failover plugins, records failover events.
    def build_wrapper_blue_failover_executing_thread(host_id:, driver:, config:, start_latch:, stop:, finish_latch:, global:, results:)
      Thread.new do
        Thread.current.name = "WrapperBGFailover@#{host_id}"
        conn = nil
        failover_occurred = false
        begin
          begin
            conn = open_wrapper_with_retry(driver, config)
          rescue StandardError => e
            LOGGER.warn { "[WrapperBGFailover@#{host_id}] Initial connection failed: #{e.class}: #{e.message}" }
            start_latch.count_down
            raise e
          end
          sleep(1)
          start_latch.count_down
          start_latch.wait(300)

          until stop.true?
            begin
              DriverHelper.execute(driver, conn, 'SELECT 1')
              if failover_occurred
                results.failover_post_reconnect_successes << TimeHolder.new(start_time: nano_time,
                                                                            end_time: nano_time)
              end
            rescue AwsAdvancedRubyDriverWrapper::Errors::FailoverSuccessError => e
              failover_occurred = true
              results.failover_success_errors << { timestamp: nano_time, message: e.message }
              LOGGER.debug { "[WrapperBGFailover@#{host_id}] FailoverSuccessError — reconnected" }
            rescue AwsAdvancedRubyDriverWrapper::Errors::FailoverFailedError => e
              results.failover_failed_errors << { timestamp: nano_time, message: e.message }
            rescue AwsAdvancedRubyDriverWrapper::Errors::BlueGreenTimeoutError => e
              results.bg_timeout_errors << { timestamp: nano_time, message: e.message }
            rescue StandardError => e
              # Other errors during transition — log but don't record as specific failures
              LOGGER.debug { "[WrapperBGFailover@#{host_id}] #{e.class}: #{e.message}" }
              conn = reconnect_if_needed(driver, conn, config)
            end
            sleep(0.5)
          end
        rescue StandardError => e
          global.unhandled_exceptions << e
        ensure
          safe_close(driver, conn)
          finish_latch.count_down
        end
      end
    end

    def topology_status_query(engine, deployment)
      case engine
      when DatabaseEngine::MYSQL
        "SELECT id, SUBSTRING_INDEX(endpoint, '.', 1) as hostId, endpoint, port, role, status, version FROM mysql.rds_topology"
      when DatabaseEngine::PG
        case deployment
        when DatabaseEngineDeployment::AURORA
          "SELECT id, SPLIT_PART(endpoint, '.', 1) as hostId, endpoint, port, role, status, version " \
          "FROM pg_catalog.get_blue_green_fast_switchover_metadata('aws_advanced_ruby_driver_wrapper-#{AwsAdvancedRubyDriverWrapper::VERSION}')"
        when DatabaseEngineDeployment::RDS_MULTI_AZ_INSTANCE
          "SELECT * FROM rds_tools.show_topology('aws_advanced_ruby_driver_wrapper-#{AwsAdvancedRubyDriverWrapper::VERSION}')"
        else
          raise "Unsupported PG deployment for topology: #{deployment}"
        end
      else
        raise "Unsupported engine for topology: #{engine}"
      end
    end

    def row_value(row, key)
      return unless row.is_a?(Hash)

      row[key] || row[key.to_sym]
    end
  end
end
