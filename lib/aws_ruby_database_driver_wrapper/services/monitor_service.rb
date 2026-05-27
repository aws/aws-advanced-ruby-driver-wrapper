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

require 'singleton'
require_relative '../monitoring/monitor_state'
require_relative '../logging'
require_relative '../log_messages'
require_relative '../utils/storage/sliding_expiration_cache'

module AwsRubyDatabaseDriverWrapper
  module Services
    # Manages monitor lifecycle: registration, deduplication, expiration, and cleanup.
    # Monitors are grouped by type (symbol) and keyed within each type.
    class MonitorService
      include Singleton
      include Logging

      CLEANUP_INTERVAL_SEC = 60

      # Internal container grouping a cache for a monitor type.
      CacheContainer = Struct.new(:cache, keyword_init: true)

      def initialize
        @caches = {}
        @lock = Mutex.new
        @running = true
        @cleanup_thread = start_cleanup_thread
        AwsRubyDatabaseDriverWrapper.shutdown_service.register(self)
      end

      # Registers a monitor type. No-op if already registered.
      # @param monitor_type [Symbol] identifier for the monitor type.
      # @param expiration_timeout_sec [Numeric] how long an unused monitor lives before expiring.
      def register_type(monitor_type, expiration_timeout_sec:)
        @lock.synchronize do
          return if @caches.key?(monitor_type)

          cache = Utils::Storage::SlidingExpirationCache.new(ttl: expiration_timeout_sec)
          @caches[monitor_type] = CacheContainer.new(cache: cache)
        end
      end

      # Returns or creates a monitor for the given type and key.
      # If the monitor already exists, extends its expiration.
      # @param monitor_type [Symbol] the registered monitor type.
      # @param key [Object] unique key for this monitor instance.
      # @param service_container [Object] passed to the initializer block.
      # @yield [service_container] block to create the monitor if absent.
      # @return [Object] the monitor instance.
      def run_if_absent(monitor_type, key, service_container)
        container = @lock.synchronize { @caches[monitor_type] }
        raise ArgumentError, "Monitor type not registered: #{monitor_type}" unless container

        container.cache.compute_if_absent(key) do
          monitor = yield(service_container)
          monitor.start
          monitor
        end
      end

      # Retrieves a monitor by type and key. Returns nil if absent or expired.
      # @param monitor_type [Symbol] the monitor type.
      # @param key [Object] the monitor key.
      # @return [Object, nil]
      def get(monitor_type, key)
        container = @lock.synchronize { @caches[monitor_type] }
        container&.cache&.get(key)
      end

      # Removes a monitor without stopping it.
      # @param monitor_type [Symbol] the monitor type.
      # @param key [Object] the monitor key.
      # @return [Object, nil] the removed monitor.
      def remove(monitor_type, key)
        container = @lock.synchronize { @caches[monitor_type] }
        container&.cache&.remove(key)
      end

      # Stops and removes a monitor.
      # @param monitor_type [Symbol] the monitor type.
      # @param key [Object] the monitor key.
      def stop_and_remove(monitor_type, key)
        monitor = remove(monitor_type, key)
        monitor&.stop
      end

      # Stops and removes all monitors across all types.
      def stop_and_remove_all
        @lock.synchronize { @caches.values }.each do |container|
          container.cache.entries.each_key do |key|
            monitor = container.cache.remove(key)
            monitor&.stop
          end
        end
      end

      # Called by ShutdownService.
      def shutdown(grace_period:)
        @running = false
        begin
          @cleanup_thread&.wakeup
        rescue ThreadError
          nil
        end
        @cleanup_thread&.join([grace_period, 5].min)
        stop_and_remove_all
      end

      private

      def start_cleanup_thread
        thread = Thread.new do
          while @running
            sleep(CLEANUP_INTERVAL_SEC)
            run_cleanup
          end
        end
        thread.name = 'monitor-service-cleanup'
        thread
      end

      def run_cleanup
        @lock.synchronize { @caches.values }.each do |container|
          cleanup_container(container)
        end
      rescue StandardError
        # Cleanup must not crash the thread.
      end

      def cleanup_container(container)
        container.cache.entries.each_key do |key|
          # Remove stopped monitors
          removed = container.cache.remove_if(key) { |m| m.state == Monitoring::MonitorState::STOPPED }
          next if removed

          # Stop and remove errored monitors
          removed = container.cache.remove_if(key) { |m| m.state == Monitoring::MonitorState::ERROR }
          if removed
            LOGGER.debug(format(LogMessages::MONITOR_SERVICE_REMOVED_ERROR, key))
            removed.stop
            next
          end

          # Remove expired monitors that can be disposed
          removed = container.cache.remove_if_expired(key)
          if removed
            LOGGER.debug(format(LogMessages::MONITOR_SERVICE_REMOVED_EXPIRED, key))
            removed.stop
          end
        end
      end
    end
  end
end
