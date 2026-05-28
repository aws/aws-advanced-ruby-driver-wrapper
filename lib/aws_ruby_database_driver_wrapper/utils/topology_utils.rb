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

require 'logger'
require_relative '../host/host_info'
require_relative '../host/host_role'
require_relative '../host/host_availability'

module AwsRubyDatabaseDriverWrapper
  module Utils
    module TopologyUtils
      DEFAULT_QUERY_TIMEOUT_MS = 1000

      attr_reader :dialect

      # Builds a HostInfo from the given topology information.
      #
      # @param instance_id [String, nil] the database instance identifier.
      # @param is_writer [Boolean] true if this is a writer instance.
      # @param weight [Integer] the instance weight for load balancing.
      # @param last_update_time [Time] the timestamp of the last update to this instance's information.
      # @param initial_host_info [AwsRubyDatabaseDriverWrapper::Host::HostInfo] the original host info used for connecting.
      # @param instance_template [AwsRubyDatabaseDriverWrapper::Host::HostInfo] the template used to construct the new HostInfo.
      # @return [AwsRubyDatabaseDriverWrapper::Host::HostInfo] a HostInfo representing the given information.
      def build_host(instance_id, is_writer, weight, last_update_time, initial_host_info, instance_template)
        instance_id = '?' if instance_id.nil?
        endpoint = instance_template.host.gsub('?', instance_id)
        port = resolve_port(instance_template, initial_host_info)
        role = is_writer ? Host::HostRole::WRITER : Host::HostRole::READER

        Host::HostInfo.new(
          host: endpoint,
          port: port,
          role: role,
          availability: Host::HostAvailability::AVAILABLE,
          weight: weight,
          id: instance_id,
          last_update_time: last_update_time
        )
      end

      # Retrieves a value from a row hash, trying both string and symbol keys.
      def row_value(row, key)
        row[key] || row[key.to_sym]
      end

      private

      def resolve_port(instance_template, initial_host_info)
        return instance_template.port if instance_template.port_specified?
        return initial_host_info.port if initial_host_info

        Host::HostInfo::NO_PORT
      end

      def logger
        @logger ||= Logger.new($stdout, progname: self.class.name)
      end
    end
  end
end
