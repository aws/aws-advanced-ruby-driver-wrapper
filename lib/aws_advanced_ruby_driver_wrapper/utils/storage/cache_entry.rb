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

module AwsAdvancedRubyDriverWrapper
  module Utils
    module Storage
      # A container that holds a cached value along with its expiration time.
      class CacheEntry
        attr_reader :value

        # @param value [Object] the cached value.
        # @param expiration_time [Float] monotonic clock time (in seconds) at which this entry expires.
        def initialize(value, expiration_time)
          @value = value
          @expiration_time = expiration_time
        end

        # @return [Boolean] true if the entry has passed its expiration time.
        def expired?
          Process.clock_gettime(Process::CLOCK_MONOTONIC) > @expiration_time
        end

        # Extends the expiration by the given TTL from the current time.
        # @param ttl [Numeric] time-to-live in seconds from now.
        def extend_expiration(ttl)
          @expiration_time = Process.clock_gettime(Process::CLOCK_MONOTONIC) + ttl
        end

        # @param other [Object] the object to compare.
        # @return [Boolean] true if both entries hold the same value.
        def ==(other)
          other.is_a?(self.class) && @value == other.value
        end

        alias eql? ==

        def hash
          value.hash
        end
      end
    end
  end
end
