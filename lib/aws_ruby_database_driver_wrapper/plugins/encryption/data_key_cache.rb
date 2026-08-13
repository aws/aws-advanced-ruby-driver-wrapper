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

require_relative '../../logging'
require_relative 'encryption_service'

module AwsRubyDatabaseDriverWrapper
  module Plugins
    module Encryption
      # An in-memory cache of plaintext data keys, so that reading an encrypted column does
      # not need a KMS Decrypt call per statement.
      #
      # This deliberately does not use the shared StorageService: data keys need a bounded
      # size with oldest-first eviction, their bytes have to be zeroed when they leave the
      # cache, and every entry is handed out as a copy so that a caller wiping its own copy
      # cannot corrupt the cached one.
      class DataKeyCache
        include Logging

        MIN_CLEANUP_INTERVAL_SEC = 30
        CLEANUP_INTERVAL_DIVISOR = 4

        # A cached plaintext data key. The stored string is private to the cache.
        CacheEntry = Data.define(:data_key, :created_at) do
          def expired?(ttl_sec, now = Process.clock_gettime(Process::CLOCK_MONOTONIC))
            now >= created_at + ttl_sec
          end
        end

        # A point-in-time snapshot of the cache counters.
        CacheStats = Data.define(:size, :hits, :misses, :evictions) do
          # @return [Float] the percentage of lookups that were served from the cache
          def hit_rate
            total = hits + misses
            total.zero? ? 0.0 : (hits.to_f / total) * 100
          end

          def to_s
            format('CacheStats{size=%<size>d, hits=%<hits>d, misses=%<misses>d, evictions=%<evictions>d, ' \
                   'hit_rate=%<hit_rate>.2f%%}',
                   size: size, hits: hits, misses: misses, evictions: evictions, hit_rate: hit_rate)
          end
        end

        # @param max_size [Integer] the maximum number of data keys held at once
        # @param ttl_sec [Numeric] how long a data key stays cached, in seconds
        # @param enabled [Boolean] when false every lookup misses and nothing is stored
        def initialize(max_size:, ttl_sec:, enabled: true)
          @max_size = max_size
          @ttl_sec = ttl_sec
          @enabled = enabled
          @cache = {}
          @lock = Mutex.new
          @hits = 0
          @misses = 0
          @evictions = 0
          @running = enabled
          @cleanup_thread = start_cleanup_thread if enabled
        end

        # @return [Boolean]
        def enabled?
          @enabled
        end

        # @param key [String] the cached data key, see {KeyManager#data_key_cache_key}
        # @return [String, nil] a copy of the cached data key, or nil on a miss
        def get(key)
          return nil unless @enabled

          @lock.synchronize do
            entry = @cache[key]

            if entry.nil?
              @misses += 1
              nil
            elsif entry.expired?(@ttl_sec)
              @cache.delete(key)
              EncryptionService.wipe(entry.data_key)
              @misses += 1
              nil
            else
              @hits += 1
              entry.data_key.dup
            end
          end
        end

        # Stores a copy of the given data key, evicting the oldest entry first when full.
        #
        # @param key [String]
        # @param data_key [String] the plaintext data key; the caller keeps ownership of it
        # @return [void]
        def put(key, data_key)
          return unless @enabled && data_key

          @lock.synchronize do
            existing = @cache.delete(key)
            EncryptionService.wipe(existing.data_key) if existing
            evict_oldest if @cache.size >= @max_size

            @cache[key] = CacheEntry.new(data_key: data_key.dup, created_at: Process.clock_gettime(Process::CLOCK_MONOTONIC))
          end
        end

        # @param key [String]
        # @return [void]
        def remove(key)
          @lock.synchronize do
            entry = @cache.delete(key)
            EncryptionService.wipe(entry.data_key) if entry
          end
        end

        # Zeroes and drops every cached data key.
        # @return [void]
        def clear
          @lock.synchronize do
            @cache.each_value { |entry| EncryptionService.wipe(entry.data_key) }
            @cache.clear
          end
        end

        # Drops every expired entry. Called on a schedule by the cleanup thread.
        # @return [Integer] the number of entries removed
        def remove_expired_entries
          @lock.synchronize do
            now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
            expired = @cache.select { |_, entry| entry.expired?(@ttl_sec, now) }
            expired.each_key do |key|
              EncryptionService.wipe(@cache.delete(key).data_key)
            end
            expired.size
          end
        end

        # @return [Integer]
        def size
          @lock.synchronize { @cache.size }
        end

        # @return [CacheStats]
        def stats
          @lock.synchronize { CacheStats.new(size: @cache.size, hits: @hits, misses: @misses, evictions: @evictions) }
        end

        # Stops the cleanup thread and zeroes every cached key.
        # @return [void]
        def shutdown
          @running = false
          begin
            @cleanup_thread&.wakeup
          rescue ThreadError
            nil
          end
          @cleanup_thread&.join(5)
          clear
        end

        private

        # Removes the entry that has been cached the longest. Callers already hold the lock.
        def evict_oldest
          oldest_key, oldest_entry = @cache.min_by { |_, entry| entry.created_at }
          return if oldest_key.nil?

          @cache.delete(oldest_key)
          EncryptionService.wipe(oldest_entry.data_key)
          @evictions += 1
        end

        def cleanup_interval_sec
          [@ttl_sec.to_f / CLEANUP_INTERVAL_DIVISOR, MIN_CLEANUP_INTERVAL_SEC].max
        end

        def start_cleanup_thread
          interval = cleanup_interval_sec
          thread = Thread.new do
            while @running
              sleep(interval)
              begin
                remove_expired_entries if @running
              rescue StandardError => e
                logger.debug("DataKeyCache cleanup failed: #{e.message}")
              end
            end
          end
          thread.name = 'encryption-data-key-cache-cleanup'
          thread
        end
      end
    end
  end
end
