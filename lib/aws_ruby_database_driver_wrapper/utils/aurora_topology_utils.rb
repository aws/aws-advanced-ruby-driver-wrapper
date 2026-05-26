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

require_relative 'single_cluster_topology_utils'

module AwsRubyDatabaseDriverWrapper
  module Utils
    # Topology utilities specific to Aurora database clusters.
    # Processes topology query results that return instance ID, writer flag, CPU utilization, and instance lag columns.
    class AuroraTopologyUtils
      include SingleClusterTopologyUtils

      def initialize(dialect:)
        @dialect = dialect
      end

      # Evaluate whether the given connection is to a writer instance.
      #
      # @param conn [Object] the connection to evaluate.
      # @return [Boolean] true if the connection is to a writer instance, false otherwise.
      def writer_instance?(conn)
        results = @dialect.execute(conn, @dialect.writer_id_query)
        return false if results.nil? || results.empty?

        row = results.first
        !row.nil? && !row.values.first.nil? && !row.values.first.to_s.empty?
      end

      # Process Aurora topology query results into a list of HostInfo objects.
      # Data in the result set is ordered by last update time, so the latest records are last.
      # Newer records replace older ones if there are duplicate hosts.
      #
      # @param results [Object] the query result set (enumerable of row hashes).
      # @param initial_host_info [AwsRubyDatabaseDriverWrapper::Host::HostInfo] the initial host info.
      # @param instance_template [AwsRubyDatabaseDriverWrapper::Host::HostInfo] the template for building hosts.
      # @return [Array<AwsRubyDatabaseDriverWrapper::Host::HostInfo>, nil] the parsed hosts or nil on failure.
      def build_hosts(_conn, results, initial_host_info, instance_template)
        hosts_map = {}

        results.each do |row|
          host = build_host_from_row(row, initial_host_info, instance_template)

          # Ensure newer records replace the older ones if there are duplicate keys.
          existing = hosts_map[host.host]
          if existing.nil? || (existing.last_update_time && host.last_update_time &&
              existing.last_update_time < host.last_update_time)
            hosts_map[host.host] = host
          end
        rescue StandardError => e
          logger.debug("Error processing topology query results: #{e.message}")
          return nil
        end

        hosts_map.values
      end

      private

      # Creates a HostInfo from a single Aurora topology query result row.
      #
      # According to the topology query, the result set should contain columns:
      # host_id, is_writer, cpu_utilization, instance_lag, last_update_time.
      #
      # @param row [Hash] a single row from the topology query result.
      # @param initial_host_info [AwsRubyDatabaseDriverWrapper::Host::HostInfo] the initial host info.
      # @param instance_template [AwsRubyDatabaseDriverWrapper::Host::HostInfo] the template for building hosts.
      # @return [AwsRubyDatabaseDriverWrapper::Host::HostInfo] the constructed host info.
      def build_host_from_row(row, initial_host_info, instance_template)
        host_id = row_value(row, "host_id")
        is_writer = to_boolean(row_value(row, "is_writer"))
        cpu_utilization = to_float(row_value(row, "cpu_utilization"))
        instance_lag = to_float(row_value(row, "instance_lag"))
        last_update_time = to_time(row_value(row, "last_update_time"))

        # Calculate weight based on instance lag and CPU utilization.
        weight = (instance_lag.round * 100) + cpu_utilization.round

        build_host(host_id, is_writer, weight, last_update_time, initial_host_info, instance_template)
      end

      def to_boolean(value)
        case value
        when true, 1, "1", "true"
          true
        else
          false
        end
      end

      def to_float(value)
        Float(value || 0)
      rescue ArgumentError, TypeError
        0.0
      end

      def to_time(value)
        case value
        when Time
          value
        when String
          Time.parse(value)
        else
          Time.now
        end
      rescue ArgumentError
        Time.now
      end
    end
  end
end
