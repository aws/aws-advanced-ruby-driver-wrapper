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

require 'aws_ruby_database_driver_wrapper'
require 'aws_ruby_database_driver_wrapper/host/host_availability'

module Integration
  # A minimal round robin host selector, for tests only. It exists so that load balancing can be
  # verified deterministically. Register it with HostService.register_host_selector.
  class TestRoundRobinHostSelector
    STRATEGY_NAME = 'test_round_robin'

    def initialize
      @lock = Mutex.new
      @counter = 0
    end

    # Selects the next available host matching the requested role from the given host list.
    #
    # @param hosts [Array<HostInfo>] list of available hosts to pick from.
    # @param role [Symbol, nil] the desired host role, or nil for no preference.
    # @param _props [Hash, nil] connection properties.
    # @return [HostInfo, nil] an available host matching the requested role, or nil if none are eligible.
    def select_host(hosts, role, _props = nil)
      eligible_hosts = hosts.select do |host|
        (role.nil? || host.role == role) &&
          host.availability == AwsRubyDatabaseDriverWrapper::Host::HostAvailability::AVAILABLE
      end

      return nil if eligible_hosts.empty?

      # Order by host name so the rotation does not depend on the order the topology happened to be
      # returned in, which would otherwise make the sequence of selected hosts unpredictable.
      eligible_hosts.sort_by!(&:host)
      eligible_hosts[next_index(eligible_hosts.size)]
    end

    private

    # @param size [Integer] the number of eligible hosts to rotate over.
    # @return [Integer] the index of the host to use for this selection.
    def next_index(size)
      @lock.synchronize do
        index = @counter % size
        @counter = index + 1
        index
      end
    end
  end
end
