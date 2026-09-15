# frozen_string_literal: true

#
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

require_relative '../../monitoring/monitor'
require_relative '../../logging'
require_relative 'info'
require_relative 'member_list_type'
require 'concurrent'

module AwsAdvancedRubyDriverWrapper
  module Plugins
    module CustomEndpoint
      class CustomEndpointMonitor < Monitoring::Monitor
        include Logging

        TERMINATION_TIMEOUT_SEC = 30.0
        ENDPOINT_INFO_EXPIRATION_SEC = 300.0
        UNAUTHORIZED_SLEEP_SEC = 300.0
        ENDPOINT_INFO_CACHE_NAME = :custom_endpoint
        ALLOWED_BLOCKED_CACHE_NAME = :custom_endpoint_allowed_blocked

        def initialize(
          service_container,
          custom_endpoint_host,
          endpoint_id,
          region,
          refresh_rate_sec,
          refresh_rate_backoff_factor,
          max_refresh_rate_sec,
          rds_client_func: ->(_, region) { Aws::RDS::Client.new(region: region) }
        )
          super(termination_timeout_sec: TERMINATION_TIMEOUT_SEC)

          @service_container = service_container
          @custom_endpoint_host = custom_endpoint_host
          @endpoint_id = endpoint_id
          @min_refresh_rate_sec = refresh_rate_sec
          @refresh_rate_sec = refresh_rate_sec
          @refresh_rate_backoff_factor = refresh_rate_backoff_factor
          @max_refresh_rate_sec = max_refresh_rate_sec
          @rds_client = rds_client_func.call(custom_endpoint_host, region)

          @refresh_mutex = Mutex.new
          @refresh_cv = ConditionVariable.new
          @refresh_required = false
          @connection_issue = false
        end

        def endpoint_info?
          info = cached_info
          request_refresh if info.nil? && @refresh_mutex.synchronize { !@refresh_required && !@connection_issue }
          !info.nil?
        end

        # Waits up to timeout_sec for the monitor to place endpoint info in the cache. Polls rather than
        # waiting on a one-shot signal: #endpoint_info? re-checks the cache and re-requests a refresh
        # (waking the monitor) on each pass, so a transient empty cache - e.g. an entry that aged out
        # between monitor iterations - is repopulated within the window instead of failing immediately.
        def wait_for_info?(timeout_sec)
          deadline = monotonic_time + timeout_sec
          loop do
            return true if endpoint_info?
            return false if monotonic_time >= deadline

            sleep(0.1)
          end
        end

        def request_endpoint_info_update
          return if @refresh_mutex.synchronize { @connection_issue }

          request_refresh
        end

        def close
          remove_cached_info
        end

        def self.clear_cache(storage_service)
          storage_service.clear(ENDPOINT_INFO_CACHE_NAME)
          storage_service.clear(ALLOWED_BLOCKED_CACHE_NAME)
        end

        private

        def monitor
          logger.debug("[#{@endpoint_id}] Started custom endpoint monitor for #{@custom_endpoint_host.url}")

          until stopped?
            update_activity
            run_monitor_iteration
          end
        rescue StandardError => e
          logger.error("[#{@endpoint_id}] Unexpected error in custom endpoint monitor: #{e.message}")
        ensure
          remove_cached_info
          logger.debug("[#{@endpoint_id}] Stopped custom endpoint monitor for #{@custom_endpoint_host.url}")
        end

        def run_monitor_iteration
          start = monotonic_time

          endpoints = fetch_endpoints
          return unless endpoints

          @refresh_mutex.synchronize do
            @connection_issue = false
            @refresh_required = false
          end

          unless valid_endpoint_count?(endpoints)
            sleep_ignoring_refresh_requests(@refresh_rate_sec)
            return
          end

          endpoint_info = Info.from_db_cluster_endpoint(endpoints.first)
          process_endpoint_info(endpoint_info, start)
        rescue Aws::RDS::Errors::ServiceError => e
          handle_rds_error(e)
        rescue StandardError => e
          logger.error("[#{@endpoint_id}] Exception monitoring #{@custom_endpoint_host.url}: #{e.message}")
          sleep_ignoring_refresh_requests(@refresh_rate_sec)
        end

        def fetch_endpoints
          response = @rds_client.describe_db_cluster_endpoints(
            db_cluster_endpoint_identifier: @endpoint_id,
            filters: [{ name: 'db-cluster-endpoint-type', values: ['custom'] }]
          )
          response.db_cluster_endpoints
        end

        def valid_endpoint_count?(endpoints)
          return true if endpoints.size == 1

          logger.warn("[#{@endpoint_id}] Expected 1 endpoint, got #{endpoints.size}: #{endpoints.map(&:endpoint)}")
          false
        end

        def process_endpoint_info(endpoint_info, start)
          if cached_info == endpoint_info
            elapsed = monotonic_time - start
            interruptible_sleep([0, @refresh_rate_sec - elapsed].max)
            return
          end

          logger.debug("[#{@endpoint_id}] Custom endpoint info changed: #{endpoint_info}")
          cache_allowed_blocked(endpoint_info)
          cache_info(endpoint_info)
          speedup_refresh_rate

          elapsed = monotonic_time - start
          interruptible_sleep([0, @refresh_rate_sec - elapsed].max)
        end

        def cache_allowed_blocked(endpoint_info)
          value = if endpoint_info.member_list_type == MemberListType::STATIC_LIST
                    { allowed: endpoint_info.static_members, blocked: nil, required_role: endpoint_info.required_role }
                  else
                    { allowed: nil, blocked: endpoint_info.excluded_members, required_role: endpoint_info.required_role }
                  end
          storage_service.set(ALLOWED_BLOCKED_CACHE_NAME, @custom_endpoint_host.url, value)
        end

        def handle_rds_error(error)
          logger.error("[#{@endpoint_id}] RDS error for #{@custom_endpoint_host.url}: #{error.message}")

          if throttling_error?(error)
            slowdown_refresh_rate
            sleep_ignoring_refresh_requests(@refresh_rate_sec)
          elsif unauthorized_error?(error)
            sleep_ignoring_refresh_requests(UNAUTHORIZED_SLEEP_SEC)
          else
            sleep_ignoring_refresh_requests(@refresh_rate_sec)
          end
        end

        def throttling_error?(error)
          error.context&.http_response&.status_code == 429 ||
            error.code == 'ThrottlingException' ||
            error.code == 'Throttling'
        end

        def unauthorized_error?(error)
          [401, 403].include?(error.context&.http_response&.status_code)
        end

        def speedup_refresh_rate
          return unless @refresh_rate_sec > @min_refresh_rate_sec

          @refresh_rate_sec = [@refresh_rate_sec / @refresh_rate_backoff_factor, @min_refresh_rate_sec].max
        end

        def slowdown_refresh_rate
          return unless @refresh_rate_sec < @max_refresh_rate_sec

          @refresh_rate_sec = [@refresh_rate_sec * @refresh_rate_backoff_factor, @max_refresh_rate_sec].min
        end

        def request_refresh
          @refresh_mutex.synchronize do
            @refresh_required = true
            @refresh_cv.broadcast
          end
        end

        # Wakes early if a refresh is requested or the monitor is stopped.
        def interruptible_sleep(duration_sec)
          end_time = monotonic_time + duration_sec
          wait_sec = [0.5, duration_sec].min

          @refresh_mutex.synchronize do
            @refresh_cv.wait(@refresh_mutex, wait_sec) until @refresh_required || monotonic_time >= end_time || stopped?
          end
        end

        # Sleeps for the full duration, ignoring refresh requests. Used on error/backoff paths
        # to prevent connections from bypassing throttling backoff.
        def sleep_ignoring_refresh_requests(duration_sec)
          end_time = monotonic_time + duration_sec
          until stopped?
            remaining = end_time - monotonic_time
            break if remaining <= 0

            sleep([0.5, remaining].min)
          end
        end

        def cached_info
          storage_service.get(ENDPOINT_INFO_CACHE_NAME, @custom_endpoint_host.url, register_access: false)
        end

        def cache_info(info)
          storage_service.set(ENDPOINT_INFO_CACHE_NAME, @custom_endpoint_host.url, info)
        end

        def remove_cached_info
          storage_service.remove(ENDPOINT_INFO_CACHE_NAME, @custom_endpoint_host.url)
          storage_service.remove(ALLOWED_BLOCKED_CACHE_NAME, @custom_endpoint_host.url)
        end

        def storage_service
          @service_container.storage_service
        end

        def monotonic_time
          Process.clock_gettime(Process::CLOCK_MONOTONIC)
        end
      end
    end
  end
end
