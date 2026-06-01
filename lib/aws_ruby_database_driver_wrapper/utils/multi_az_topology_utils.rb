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

require_relative 'topology_utils'

module AwsRubyDatabaseDriverWrapper
  module Utils
    # Topology utilities specific to Multi-AZ database clusters.
    # In Multi-AZ clusters, the writer is identified via a separate query rather than
    # from a column in the topology results.
    class MultiAzTopologyUtils
      include TopologyUtils

      def initialize(dialect:)
        raise ArgumentError, 'dialect cannot be nil' if dialect.nil?

        @dialect = dialect
      end

      # Evaluate whether the given connection is to a writer instance.
      # In Multi-AZ, when connected to a writer, the writer ID query returns no rows.
      #
      # @param conn [Object] the connection to evaluate.
      # @return [Boolean] true if the connection is to a writer instance, false otherwise.
      def writer_instance?(conn)
        results = @dialect.execute(conn, @dialect.writer_id_query)
        # When connected to a writer, the result is empty; otherwise it contains a single row.
        results.nil? || results.empty?
      end

      # Process Multi-AZ topology query results into a list of HostInfo objects.
      # First determines the writer ID, then parses each row using endpoint and id columns.
      #
      # @param conn [Object] the database connection.
      # @param results [Object] the query result set (enumerable of row hashes).
      # @param initial_host_info [AwsRubyDatabaseDriverWrapper::Host::HostInfo] the initial host info.
      # @param instance_template [AwsRubyDatabaseDriverWrapper::Host::HostInfo] the template for building hosts.
      # @return [Array<AwsRubyDatabaseDriverWrapper::Host::HostInfo>, nil] the parsed hosts or nil on failure.
      def build_hosts(conn, results, initial_host_info, instance_template)
        hosts_map = {}
        writer_id = query_writer_id(conn)

        results.each do |row|
          host = build_host_from_row(row, initial_host_info, instance_template, writer_id)

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

      # Determines the writer instance ID by querying the database.
      # The writer ID query returns the writer ID when connected to a reader.
      # When connected to a writer, the query returns no rows, so we fall back to
      # getting the host ID of the current connection.
      #
      # @param conn [Object] the database connection.
      # @return [String, nil] the writer instance ID, or nil if it cannot be determined.
      def query_writer_id(conn)
        results = @dialect.execute(conn, @dialect.writer_id_query)

        if results && !results.empty?
          row = results.first
          writer_id_column = @dialect.respond_to?(:writer_id_column_name) ? @dialect.writer_id_column_name : 'writer_id'
          writer_id = row_value(row, writer_id_column)
          return writer_id unless writer_id.nil? || writer_id.to_s.empty?
        end

        # The writer ID is only returned when connected to a reader.
        # If the query does not return a value, we are connected to the writer.
        instance_id, = @dialect.instance_identity(conn)
        instance_id
      rescue StandardError
        nil
      end

      # Builds a HostInfo from a single Multi-AZ topology query result row.
      # Expected columns: endpoint.
      #
      # @param row [Hash] a single row from the topology query result.
      # @param initial_host_info [AwsRubyDatabaseDriverWrapper::Host::HostInfo] the initial host info.
      # @param instance_template [AwsRubyDatabaseDriverWrapper::Host::HostInfo] the template for building hosts.
      # @param writer_id [String, nil] the writer instance ID.
      # @return [AwsRubyDatabaseDriverWrapper::Host::HostInfo] the constructed host info.
      def build_host_from_row(row, initial_host_info, instance_template, writer_id)
        instance_id = row_value(row, 'instance_id')
        endpoint = row_value(row, 'endpoint')
        # Extract instance name from the endpoint (everything before the first dot).
        instance_name = endpoint&.split('.')&.first
        build_host(instance_id, instance_name, instance_id == writer_id, 0, Time.now, initial_host_info, instance_template)
      end
    end
  end
end
