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

module Integration
  module RetryHelper
    DEFAULT_TIMEOUT_SECS = 300
    DEFAULT_DELAY_SECS = 5

    # Retries the given block until it returns true or the timeout is reached.
    #
    # @param timeout_secs [Numeric] the maximum monotonic time to wait in seconds (default: 300)
    # @param delay_secs [Numeric] the delay between retries in seconds (default: 5)
    # @yield a block that returns true when the retry loop should exit
    # @return [Boolean] true if the condition was met within the timeout, false otherwise
    def self.retry_until(timeout_secs: DEFAULT_TIMEOUT_SECS, delay_secs: DEFAULT_DELAY_SECS)
      start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      loop do
        return true if yield
        return false if Process.clock_gettime(Process::CLOCK_MONOTONIC) - start >= timeout_secs

        sleep(delay_secs)
      end
    end

    # Retries until the cluster's writer instance matches the expected ID.
    #
    # @param rds_util [RdsTestUtility] utility used to query the current writer instance
    # @param expected_writer_id [String] the expected writer instance identifier
    # @param timeout_secs [Numeric] the maximum monotonic time to wait in seconds (default: 300)
    # @param delay_secs [Numeric] the delay between retries in seconds (default: 5)
    # @return [Boolean] true if the writer matched within the timeout, false otherwise
    def self.verify_writer(rds_util, expected_writer_id, timeout_secs: DEFAULT_TIMEOUT_SECS, delay_secs: DEFAULT_DELAY_SECS)
      retry_until(timeout_secs: timeout_secs, delay_secs: delay_secs) do
        api_writer_id = rds_util.cluster_writer_instance_id
        expected_writer_id.casecmp?(api_writer_id)
      end
    end
  end
end
