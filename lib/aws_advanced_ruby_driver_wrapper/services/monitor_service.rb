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

require_relative '../monitoring/monitor_state'
require_relative '../logging'
require_relative '../utils/storage/sliding_expiration_cache'
require_relative '../utils/events/data_access_event'

module AwsAdvancedRubyDriverWrapper
  module Services
    # Manages monitor lifecycle: registration, deduplication, expiration, and cleanup.
    # Monitors are grouped by type (symbol) and keyed within each type.
    # Subscribes to DataAccessEvent to extend monitor TTLs.
    class MonitorService
      include Logging

      CLEANUP_INTERVAL_SEC = 60.0

      # Internal container grouping a cache for a monitor type.
      CacheContainer = Data.define(:cache, :produced_data_type)

      # @param event_publisher [#subscribe] the event publisher to subscribe to.
      def initialize(event_publisher:)
        @caches = {}
        @lock = Mutex.new
        @running = true
        @cleanup_thread = start_cleanup_thread
        event_publisher.subscribe(
          self,
          Set[Utils::Events::DataAccessEvent]
        )
      end

      # Registers a monitor type. No-op if already registered.
      # @param monitor_type [Symbol] identifier for the monitor type.
      # @param expiration_timeout_sec [Numeric] how long an unused monitor lives before expiring.
      # @param produced_data_type [Symbol, nil] the data type this monitor produces (for DataAccessEvent linking).
      def register_type(monitor_type, expiration_timeout_sec:, produced_data_type: nil)
        @lock.synchronize do
          return if @caches.key?(monitor_type)

          cache = Utils::Storage::SlidingExpirationCache.new(ttl: expiration_timeout_sec)
          @caches[monitor_type] = CacheContainer.new(cache:, produced_data_type:)
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

      # Processes events from the event publisher.
      # @param event [Event] the event to process.
      def process_event(event)
        return unless event == Utils::Events::DataAccessEvent

        handle_data_access_event(event)
      end

      private

      def handle_data_access_event(event)
        @lock.synchronize { @caches.values }.each do |container|
          next unless container.produced_data_type == event.data_type

          container.cache.extend_expiration(event.key)
        end
      end

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
            logger.debug("Removed monitor in error state: #{key}")
            removed.stop
            next
          end

          # Remove expired monitors that can be disposed
          removed = container.cache.remove_if_expired(key)
          if removed
            logger.debug("Removed expired monitor: #{key}")
            removed.stop
          end
        end
      end
    end
  end
end
