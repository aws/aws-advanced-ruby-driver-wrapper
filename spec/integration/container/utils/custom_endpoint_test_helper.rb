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
require_relative 'blue_green_test_helper'
require_relative 'driver_helper'

module Integration
  class CustomEndpointResults
    attr_reader :execute_times, :failover_success_errors, :failover_failed_errors,
                :post_failover_execute_times, :unexpected_errors

    def initialize
      @execute_times = Concurrent::Array.new
      @failover_success_errors = Concurrent::Array.new
      @failover_failed_errors = Concurrent::Array.new
      @post_failover_execute_times = Concurrent::Array.new
      @unexpected_errors = Concurrent::Array.new
    end
  end

  class CustomEndpointGlobalResults
    attr_reader :unhandled_exceptions, :initial_instance_id, :post_failover_instance_id, :timed_out

    def initialize
      @unhandled_exceptions = Concurrent::Array.new
      @initial_instance_id = Concurrent::AtomicReference.new(nil)
      @post_failover_instance_id = Concurrent::AtomicReference.new(nil)
      @timed_out = Concurrent::AtomicBoolean.new(false)
    end

    def timed_out?
      @timed_out.true?
    end
  end

  module CustomEndpointObserverThreads
    module_function

    LOGGER = Logger.new($stdout, progname: 'CustomEndpointObserverThreads')

    def nano_time
      Process.clock_gettime(Process::CLOCK_MONOTONIC, :nanosecond)
    end

    def safe_close(driver, conn)
      return if conn.nil?

      DriverHelper.close(driver, conn)
    rescue StandardError
      # ignore
    end

    def build_custom_endpoint_executing_thread(driver:, config:, rds_util:, start_latch:, stop:,
                                               finish_latch:, results:, global:)
      Thread.new do
        Thread.current.name = 'CustomEndpointExecute'
        conn = nil
        failover_occurred = false
        begin
          begin
            conn = DriverHelper.wrapper_connect(driver, **config)
          rescue StandardError => e
            LOGGER.warn { "[CustomEndpointExecute] Initial connection failed: #{e.class}: #{e.message}" }
            start_latch.count_down
            raise e
          end

          instance_id = rds_util.query_instance_id(conn)
          global.initial_instance_id.set(instance_id)
          LOGGER.debug { "[CustomEndpointExecute] Connected to #{instance_id}" }

          sleep(1)
          start_latch.count_down
          start_latch.wait(300)

          until stop.true?
            start_t = nano_time
            begin
              instance_id = rds_util.query_instance_id(conn)
              end_t = nano_time
              if failover_occurred
                global.post_failover_instance_id.compare_and_set(nil, instance_id)
                results.post_failover_execute_times << TimeHolder.new(start_time: start_t, end_time: end_t)
              else
                results.execute_times << TimeHolder.new(start_time: start_t, end_time: end_t)
              end
            rescue AwsAdvancedRubyDriverWrapper::Errors::FailoverSuccessError => e
              end_t = nano_time
              failover_occurred = true
              results.failover_success_errors << { timestamp: end_t, message: e.message }
              LOGGER.debug { '[CustomEndpointExecute] FailoverSuccessError — reconnected' }
            rescue AwsAdvancedRubyDriverWrapper::Errors::FailoverFailedError => e
              end_t = nano_time
              results.failover_failed_errors << { timestamp: end_t, message: e.message }
              LOGGER.warn { "[CustomEndpointExecute] FailoverFailedError: #{e.message}" }
              break
            rescue StandardError => e
              end_t = nano_time
              results.execute_times << TimeHolder.new(start_time: start_t, end_time: end_t, error: e.message)
              results.unexpected_errors << { error_class: e.class.name, message: e.message }
              LOGGER.debug { "[CustomEndpointExecute] #{e.class}: #{e.message}" }
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

    def build_failover_trigger_thread(rds_util:, pre_trigger_delay_sec:, start_latch:,
                                      finish_latch:, global:)
      Thread.new do
        Thread.current.name = 'FailoverTrigger'
        begin
          start_latch.count_down
          start_latch.wait(300)

          LOGGER.info { "[FailoverTrigger] Waiting #{pre_trigger_delay_sec}s before triggering failover" }
          sleep(pre_trigger_delay_sec)

          LOGGER.info { '[FailoverTrigger] Triggering cluster failover' }
          rds_util.failover_cluster_and_wait_until_writer_changed
          LOGGER.info { '[FailoverTrigger] Failover complete' }
        rescue StandardError => e
          global.unhandled_exceptions << e
        ensure
          finish_latch.count_down
        end
      end
    end
  end
end
