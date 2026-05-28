# frozen_string_literal: true

# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
#
# Licensed under the Apache License, Version 2.0 (the "License").
# You may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
# http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

require_relative 'expiration_cache'
require_relative '../../logging'

module AwsRubyDatabaseDriverWrapper
  module Utils
    module Storage
      # A centralized, shared cache registry with per-type TTL and background cleanup.
      # Each named cache partition stores items independently with its own expiration policy.
      class StorageService
        include Logging

        DEFAULT_CLEANUP_INTERVAL = 300 # 5 minutes in seconds

        @lock = Mutex.new
        @shared_instance = nil

        # Returns the shared instance, creating it if needed.
        # @param cleanup_interval [Numeric] seconds between cleanup runs.
        # @return [StorageService]
        def self.shared_instance(cleanup_interval: DEFAULT_CLEANUP_INTERVAL)
          @lock.synchronize do
            @shared_instance ||= new(cleanup_interval: cleanup_interval)
          end
        end

        # Resets the shared instance. For testing only.
        # @api private
        def self.reset!
          @lock.synchronize do
            @shared_instance&.shutdown
            @shared_instance = nil
          end
        end

        # @param cleanup_interval [Numeric] seconds between cleanup runs.
        def initialize(cleanup_interval: DEFAULT_CLEANUP_INTERVAL)
          @caches = {}
          @lock = Mutex.new
          @running = true
          @cleanup_thread = start_cleanup_thread(cleanup_interval)
        end

        # Registers a named cache. No-op if already registered.
        #
        # @param name [Symbol] cache partition name.
        # @param ttl [Numeric] time-to-live in seconds.
        def register(name, ttl:)
          @lock.synchronize do
            return if @caches.key?(name)

            @caches[name] = ExpirationCache.new(ttl: ttl)
          end
        end

        # Stores an item.
        # @param name [Symbol] registered cache name.
        # @param key [Object] item key.
        # @param value [Object] item to store.
        def set(name, key, value)
          fetch_cache!(name).put(key, value)
        end

        # Retrieves an item. Returns nil if absent or expired.
        # @param name [Symbol] registered cache name.
        # @param key [Object] item key.
        # @return [Object, nil]
        def get(name, key)
          fetch_cache!(name).get(key)
        end

        # Returns true if a non-expired item exists at the given name + key.
        # @param name [Symbol] registered cache name.
        # @param key [Object] item key.
        # @return [Boolean]
        def exists?(name, key)
          !get(name, key).nil?
        end

        # Removes an item.
        # @param name [Symbol] registered cache name.
        # @param key [Object] item key.
        def remove(name, key)
          fetch_cache!(name).remove(key)
        end

        # Clears all items for a given name.
        # @param name [Symbol] registered cache name.
        def clear(name)
          fetch_cache!(name).clear
        end

        # Clears all items from all registered caches.
        def clear_all
          @lock.synchronize { @caches.keys }.each { |name| clear(name) }
        end

        # Returns the number of items (including expired) for a given name.
        # @param name [Symbol] registered cache name.
        # @return [Integer]
        def size(name)
          fetch_cache!(name).size
        end

        # Stops the cleanup thread.
        def shutdown
          @running = false
          begin
            @cleanup_thread&.wakeup
          rescue ThreadError
            nil
          end
          @cleanup_thread&.join(5)
        end

        private

        def fetch_cache!(name)
          cache = @caches[name]
          raise ArgumentError, "Cache not registered: #{name.inspect}" unless cache

          cache
        end

        def start_cleanup_thread(interval)
          thread = Thread.new do
            while @running
              sleep(interval)
              remove_expired_items
            end
          end
          thread.name = 'storage-service-cleanup'
          thread
        end

        def remove_expired_items
          @lock.synchronize { @caches.keys }.each do |name|
            cache = @caches[name]
            next unless cache

            cache.remove_expired_entries
          rescue StandardError => e
            logger.debug("StorageService cleanup failed for #{name}: #{e.message}")
          end
        end
      end
    end
  end
end
