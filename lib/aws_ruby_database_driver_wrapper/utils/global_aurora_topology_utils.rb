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

require_relative '../host/host_role'
require_relative 'rds_url_type'
require_relative 'rds_utils'
require_relative 'aurora_topology_utils'

module AwsRubyDatabaseDriverWrapper
  module Utils
    # Topology utilities specific to Global Aurora database clusters.
    # Global Aurora clusters span multiple AWS regions, so topology queries return a region column
    # and instance templates are keyed by region.
    class GlobalAuroraTopologyUtils < AuroraTopologyUtils
      # Query the database for topology information across global Aurora cluster regions.
      #
      # @param conn [Object] the connection to use to query the database.
      # @param initial_host_info [AwsRubyDatabaseDriverWrapper::Host::HostInfo] the HostInfo used to initially connect.
      # @param instance_templates_by_region [Hash<String, AwsRubyDatabaseDriverWrapper::Host::HostInfo>]
      #   a map of AWS region to instance template HostInfo for constructing hosts.
      # @return [Array<AwsRubyDatabaseDriverWrapper::Host::HostInfo>, nil] a list of HostInfo objects or nil.
      def query_topology(conn, initial_host_info, instance_templates_by_region)
        results = @dialect.execute(conn, @dialect.topology_query)

        if results.fields.empty?
          # We expect at least 4 columns. Note that the server may return 0 columns if failover has occurred.
          logger.debug('The topology query returned a result with 0 columns. ' \
                       'This may occur if the topology query is executed when the server is failing over.')
          return nil
        end

        verify_writer(build_global_hosts(results, initial_host_info, instance_templates_by_region))
      rescue StandardError => e
        raise "Invalid topology query: #{e.message}"
      end

      # Retrieves the AWS region for a given instance ID.
      #
      # @param instance_id [String] the database instance identifier.
      # @param conn [Object] the database connection.
      # @return [String, nil] the AWS region, or nil if it cannot be determined.
      def query_region(instance_id, conn)
        results = @dialect.execute(conn, @dialect.region_by_instance_id_query(instance_id))
        return nil if results.nil? || results.empty?

        row = results.first
        region = row.values.first
        region.nil? || region.to_s.empty? ? nil : region.to_s
      end

      # Parses a comma-separated instance templates string into a region-to-HostInfo map.
      # Each comma-separated entry in the string can be one of the following formats:
      #   - "host_pattern"
      #   - "host_pattern:port"
      #   - "[region]host_pattern"
      #   - "[region]host_pattern:port"
      #
      # @param instance_templates_string [String] comma-separated list of instance template entries.
      # @param host_validator [Proc] proc to validate each host pattern.
      # @return [Hash<String, AwsRubyDatabaseDriverWrapper::Host::HostInfo>] map of region to instance template.
      # @raise [AwsError] if the host or region in any of the template strings could not be parsed.
      def parse_instance_templates(instance_templates_string, host_validator)
        templates = {}

        instance_templates_string.split(',').each do |entry|
          entry = entry.strip
          region, host_pattern, port = extract_region_host_and_port(entry)
          raise Errors::AwsError, "Unable to parse region from '#{entry}'" if region.nil? || region.empty?
          raise Errors::AwsError, "Unable to parse host from '#{entry}'" if host_pattern.nil? || host_pattern.empty?

          host_validator.call(host_pattern)
          url_type = RdsUtils.identify_rds_type(host_pattern)
          # assign HostRole of READER if using the reader cluster URL, otherwise assume a HostRole of WRITER
          role = url_type == RdsUrlType::RDS_READER_CLUSTER ? Host::HostRole::READER : Host::HostRole::WRITER
          templates[region] = Host::HostInfo.new(id: '?', host: host_pattern, port: port, role: role)
        end

        logger.debug("Detected global database patterns: #{templates}")
        templates
      end

      private

      # Process global Aurora topology query results into a list of HostInfo objects.
      # Each row in 'results' includes a region column used to select the appropriate instance template.
      #
      # @param results [Object] the query result set (enumerable of row hashes).
      # @param initial_host_info [AwsRubyDatabaseDriverWrapper::Host::HostInfo] the initial host info.
      # @param instance_templates_by_region [Hash<String, AwsRubyDatabaseDriverWrapper::Host::HostInfo>]
      #   map of region to instance template.
      # @return [Array<AwsRubyDatabaseDriverWrapper::Host::HostInfo>, nil] the parsed hosts or nil on failure.
      def build_global_hosts(results, initial_host_info, instance_templates_by_region)
        hosts_map = {}

        results.each do |row|
          host = build_host_from_row(row, initial_host_info, instance_templates_by_region)
          hosts_map[host.host] = host
        rescue StandardError => e
          logger.debug("Error processing topology query results: #{e.message}")
          return nil
        end

        hosts_map.values
      end

      # Builds a HostInfo from a single global Aurora topology query result row.
      #
      # Expected columns: host_id, is_writer, node_lag, aws_region.
      #
      # @param row [Hash] a single row from the topology query result.
      # @param initial_host_info [AwsRubyDatabaseDriverWrapper::Host::HostInfo] the initial host info.
      # @param instance_templates_by_region [Hash<String, AwsRubyDatabaseDriverWrapper::Host::HostInfo>]
      #   map of region to instance template.
      # @return [AwsRubyDatabaseDriverWrapper::Host::HostInfo] the constructed host info.
      # @raise [AwsError] if no template is found for the row's region.
      def build_host_from_row(row, initial_host_info, instance_templates_by_region)
        host_id = row_value(row, 'host_id')
        is_writer = to_boolean(row_value(row, 'is_writer'))
        lag = to_float(row_value(row, 'node_lag'))
        aws_region = row_value(row, 'aws_region').to_s

        weight = (lag.round * 100)

        instance_template = instance_templates_by_region[aws_region]
        raise Errors::AwsError, "Cannot find instance template for region '#{aws_region}'" if instance_template.nil?

        build_host(host_id, is_writer, weight, Time.now, initial_host_info, instance_template)
      end

      # Extracts the region, host pattern, and port from an instance template string.
      # The region may be prefixed in square brackets or inferred from the host pattern, for example:
      # - "[us-west-1]?.custom-host:5432"
      # - "?.xyz.us-west-1.rds.amazonaws.com:5432"
      #
      # @param entry [String] a single instance template entry.
      # @return [Array(String, String, Integer)] region, host_pattern, and port.
      def extract_region_host_and_port(entry)
        if entry.start_with?('[')
          closing = entry.index(']')
          raise ArgumentError, "Invalid instance template format: '#{entry}'" if closing.nil?

          region = entry[1...closing]
          host_pattern, port = parse_host_and_port(entry[(closing + 1)..])
        else
          host_pattern, port = parse_host_and_port(entry)
          region = RdsUtils.rds_region(host_pattern)
        end

        [region, host_pattern, port]
      end

      # Parses "host_pattern" or "host_pattern:port" and returns [host_pattern, port].
      def parse_host_and_port(value)
        # Split from the right to handle host patterns that might not contain a colon.
        # Only treat the last segment as a port if it's purely numeric.
        last_colon = value.rindex(':')
        if last_colon && value[(last_colon + 1)..].match?(/\A\d+\z/)
          host_pattern = value[0...last_colon]
          port = value[(last_colon + 1)..].to_i
          [host_pattern, port]
        else
          [value, Host::HostInfo::NO_PORT]
        end
      end
    end
  end
end
