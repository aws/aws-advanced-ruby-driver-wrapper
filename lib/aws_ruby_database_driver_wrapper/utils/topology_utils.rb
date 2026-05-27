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
require_relative '../logging'

module AwsRubyDatabaseDriverWrapper
  module Utils
    # A mixin providing shared utility methods for retrieving and processing single-cluster topology information.
    # Classes that include this module must implement:
    #   - #build_hosts(conn, results, initial_host_info, instance_template) => Array<HostInfo> or nil
    module TopologyUtils
      include Logging

      attr_reader :dialect

      # Builds a HostInfo from the given topology information.
      #
      # @param instance_id [String, nil] the database instance identifier, e.g. "mydb-instance-1" (Aurora) or "123456789" (Multi-AZ).
      # @param instance_name [String, nil] the database instance name, e.g. "mydb-instance-1" (Aurora and Multi-AZ).
      # @param is_writer [Boolean] true if this is a writer instance.
      # @param weight [Integer] the instance weight for load balancing.
      # @param last_update_time [Time] the timestamp of the last update to this instance's information.
      # @param initial_host_info [AwsRubyDatabaseDriverWrapper::Host::HostInfo] the original host info used for connecting.
      # @param instance_template [AwsRubyDatabaseDriverWrapper::Host::HostInfo] the template used to construct the new HostInfo.
      # @return [AwsRubyDatabaseDriverWrapper::Host::HostInfo] a HostInfo representing the given information.
      def build_host(instance_id, instance_name, is_writer, weight, last_update_time, initial_host_info, instance_template)
        instance_name = '?' if instance_name.nil?
        endpoint = instance_template.host.gsub('?', instance_name)
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

      # Query the database for information for each instance in the database topology.
      #
      # @param conn [Object] the connection to use to query the database.
      # @param initial_host_info [AwsRubyDatabaseDriverWrapper::Host::HostInfo] the HostInfo used to initially connect.
      # @param instance_template [AwsRubyDatabaseDriverWrapper::Host::HostInfo] the template HostInfo to use when
      #   constructing new HostInfo objects from the data returned by the topology query.
      # @return [Array<AwsRubyDatabaseDriverWrapper::Host::HostInfo>, nil] a list of HostInfo objects representing
      #   the results of the topology query, or nil if the query returned unexpected results.
      def query_topology(conn, initial_host_info, instance_template)
        results = @dialect.execute(conn, @dialect.topology_query)
        # We expect at least 4 columns. Note that the server may return 0 columns if failover has occurred.
        if results.fields.empty?
          logger.debug('The topology query returned a result with 0 columns. ' \
                       'This may occur if the topology query is executed when the server is failing over.')
          return nil
        end

        verify_writer(build_hosts(conn, results, initial_host_info, instance_template))
      end

      private

      # Verifies the writer in the host list. If multiple writers exist, the one with the most recent
      # last_update_time is used as the current writer.
      #
      # @param all_hosts [Array<AwsRubyDatabaseDriverWrapper::Host::HostInfo>, nil] the list of all hosts.
      # @return [Array<AwsRubyDatabaseDriverWrapper::Host::HostInfo>, nil] the verified host list, or nil if no writer found.
      def verify_writer(all_hosts)
        return nil if all_hosts.nil?

        hosts = []
        writers = []

        all_hosts.each do |host|
          if host.role == Host::HostRole::WRITER
            writers << host
          else
            hosts << host
          end
        end

        return nil if writers.empty?

        if writers.size == 1
          hosts << writers.first
        else
          # Assume the latest updated writer instance is the current writer.
          sorted_writers = writers.sort_by { |w| w.last_update_time || Time.at(0) }.reverse
          hosts << sorted_writers.first
        end

        hosts
      end

      def resolve_port(instance_template, initial_host_info)
        return instance_template.port if instance_template.port_specified?
        return initial_host_info.port if initial_host_info

        Host::HostInfo::NO_PORT
      end
    end
  end
end
