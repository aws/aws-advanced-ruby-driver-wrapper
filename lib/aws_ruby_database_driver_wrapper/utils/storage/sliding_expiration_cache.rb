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

require_relative 'cache_entry'

module AwsRubyDatabaseDriverWrapper
  module Utils
    module Storage
      # A thread-safe cache with sliding TTL expiration. Accessing an existing entry
      # via {#compute_if_absent} renews its expiration, and {#extend_expiration} allows
      # manual renewal. Provides conditional removal via {#remove_if} and
      # {#remove_expired_if} for entries that require careful lifecycle management.
      # Disposal of removed items should be handled by the caller.
      #
      # For simple data that does not need expiration renewal or controlled removal,
      # see {ExpirationCache}.
      class SlidingExpirationCache
        DEFAULT_TTL = 900 # 15 minutes in seconds

        # @param ttl [Numeric] time-to-live for cache entries in seconds.
        def initialize(ttl: DEFAULT_TTL)
          @cache = {}
          @ttl = ttl
          @lock = Mutex.new
        end

        # Retrieves the value at the given key. Returns nil if absent or expired.
        # @param key [Object] the cache key.
        # @return [Object, nil] the cached value, or nil.
        def get(key)
          @lock.synchronize do
            entry = @cache[key]
            return nil if entry.nil? || entry.expired?

            entry.value
          end
        end

        # Computes and stores a value if the key is absent.
        # If the key exists, extends its expiration and returns the existing value, even if it is expired.
        # @param key [Object] the cache key.
        # @yield [key] block to compute the value if absent.
        # @return [Object] the current (existing or computed) value.
        def compute_if_absent(key)
          @lock.synchronize do
            entry = @cache[key]

            if entry.nil?
              value = yield(key)
              @cache[key] = new_cache_entry(value)
              return value
            end

            entry.extend_expiration(@ttl)
            entry.value
          end
        end

        # Extends the expiration of the entry at the given key, if it exists.
        # @param key [Object] the cache key.
        def extend_expiration(key)
          @lock.synchronize do
            entry = @cache[key]
            entry&.extend_expiration(@ttl)
          end
        end

        # Removes the value at the given key.
        # @param key [Object] the cache key.
        # @return [Object, nil] the removed value, or nil.
        def remove(key)
          @lock.synchronize do
            entry = @cache.delete(key)
            entry&.value
          end
        end

        # Removes the value at the given key only if the predicate returns true.
        # @param key [Object] the cache key.
        # @yield [value] block that returns true if the value should be removed.
        # @return [Object, nil] the removed value, or nil.
        def remove_if(key)
          @lock.synchronize do
            entry = @cache[key]
            return nil if entry.nil?
            return nil unless yield(entry.value)

            @cache.delete(key)
            entry.value
          end
        end

        # Removes the value at the given key only if it is expired and the predicate returns true.
        # @param key [Object] the cache key.
        # @yield [value] block that returns true if the expired value should be removed.
        # @return [Object, nil] the removed value, or nil.
        def remove_expired_if(key)
          @lock.synchronize do
            entry = @cache[key]
            return nil if entry.nil?
            return nil unless entry.expired? && yield(entry.value)

            @cache.delete(key)
            entry.value
          end
        end

        # Returns a hash copy of all entries (including expired ones).
        # @return [Hash]
        def entries
          @lock.synchronize do
            @cache.transform_values(&:value)
          end
        end

        private

        def new_cache_entry(value)
          CacheEntry.new(value, Process.clock_gettime(Process::CLOCK_MONOTONIC) + @ttl)
        end
      end
    end
  end
end
