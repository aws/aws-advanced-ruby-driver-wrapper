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

module AwsRubyDatabaseDriverWrapper
  module Host
    class RandomHostSelector
      STRATEGY_NAME = 'random'

      # Selects a random available host matching the requested role from the given host list.
      #
      # @param hosts [Array<HostInfo>] list of available hosts to pick from.
      # @param role [Symbol, nil] the desired host role, or nil for no preference.
      # @param _props [Hash, nil] connection properties.
      # @return [HostInfo, nil] an available host matching the requested role, or nil if none are eligible.
      def select_host(hosts, role, _props = nil)
        eligible_hosts = hosts.select do |host|
          (role.nil? || host.role == role) &&
            host.availability == HostAvailability::AVAILABLE
        end

        return nil if eligible_hosts.empty?

        eligible_hosts.sample
      end
    end
  end
end
