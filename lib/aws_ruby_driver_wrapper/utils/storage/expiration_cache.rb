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

module AwsRubyDriverWrapper
  module Utils
    module Storage
      # A thread-safe cache with fixed TTL expiration. Entries expire after a set duration
      # and are not renewed on access. Expired entries are removed on read or via
      # {#remove_expired_entries}. Suitable for simple data that does not require
      # special cleanup when removed.
      #
      # For entries that need sliding expiration or controlled removal,
      # see {SlidingExpirationCache}.
      class ExpirationCache
        DEFAULT_TTL = 300 # 5 minutes in seconds

        # @param ttl [Numeric] time-to-live for cache entries in seconds.
        def initialize(ttl: DEFAULT_TTL)
          @cache = {}
          @ttl = ttl
          @lock = Mutex.new
        end

        # Stores the given value at the given key.
        # @param key [Object] the cache key.
        # @param value [Object] the value to store.
        # @return [Object, nil] the previous value, or nil.
        def put(key, value)
          @lock.synchronize do
            previous = @cache[key]
            @cache[key] = new_cache_entry(value)

            previous&.value
          end
        end

        # Retrieves the value at the given key. Returns nil if absent or expired.
        # @param key [Object] the cache key.
        # @return [Object, nil] the cached value, or nil.
        def get(key)
          @lock.synchronize do
            entry = @cache[key]
            return nil if entry.nil?

            if entry.expired?
              @cache.delete(key)
              return nil
            end

            entry.value
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

        # Removes all entries.
        def clear
          @lock.synchronize do
            @cache.clear
          end
        end

        # @return [Integer] the number of entries (including expired ones).
        def size
          @lock.synchronize do
            @cache.size
          end
        end

        # Removes expired entries from the cache.
        def remove_expired_entries
          @lock.synchronize do
            @cache.delete_if { |_key, entry| entry.expired? }
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
