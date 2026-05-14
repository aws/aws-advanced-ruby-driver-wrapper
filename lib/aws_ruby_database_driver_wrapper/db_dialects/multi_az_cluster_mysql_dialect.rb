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

require_relative 'mysql_dialect'
require_relative 'multi_az_cluster_dialect'

module AwsAdvancedRubyWrapper
  module DbDialects
    class MultiAzClusterMysqlDialect < MysqlDialect
      include MultiAzClusterDialect

      REPORT_HOST_EXISTS_QUERY = <<~SQL.freeze
        SHOW VARIABLES LIKE 'report_host'
      SQL

      TOPOLOGY_TABLE_EXISTS_QUERY = <<~SQL.freeze
        SELECT 1 AS tmp FROM information_schema.tables WHERE
        table_schema = 'mysql' AND table_name = 'rds_topology'
      SQL

      TOPOLOGY_QUERY = <<~SQL.freeze
        SELECT id, endpoint, port FROM mysql.rds_topology
      SQL

      INSTANCE_ID_QUERY = <<~SQL.freeze
        SELECT id, SUBSTRING_INDEX(endpoint, '.', 1)
        FROM mysql.rds_topology
        WHERE id = @@server_id
      SQL

      WRITER_ID_QUERY = <<~SQL.freeze
        SHOW REPLICA STATUS
      SQL

      WRITER_ID_QUERY_COLUMN_NAME = "Source_Server_Id".freeze

      FAILOVER_RESTRICTIONS = [
        :disable_task_a,
        :enable_writer_in_task_b
      ].freeze

      def initialize
        super
        @rds_utils = RdsUtils.new
      end

      def dialect?(connection)
        @dialect_utils ||= DialectUtils.new
        return false unless @dialect_utils.check_existence_queries(
          connection, TOPOLOGY_TABLE_EXISTS_QUERY, TOPOLOGY_QUERY
        )

        begin
          result = connection.query(REPORT_HOST_EXISTS_QUERY)
          return false if result.empty?

          row = result.first
          report_host = row.is_a?(Hash) ? row.values[1] : row[1]
          !report_host.nil? && !report_host.empty?
        rescue StandardError
          false
        end
      end

      def dialect_update_candidates
        nil
      end

      def host_list_provider
        @host_list_provider ||= begin
          topology_utils = MultiAzTopologyUtils.new(self)
          RdsHostListProvider.new(topology_utils)
        end
      end

      def prepare_connect_properties(connect_properties, protocol, host_spec)
        connection_attributes = "_jdbc_wrapper_name:aws_jdbc_driver,_jdbc_wrapper_version:#{AwsAdvancedRubyWrapper::VERSION}"
        
        existing_attributes = connect_properties['connectionAttributes']
        connect_properties['connectionAttributes'] = if existing_attributes.nil?
                                                       connection_attributes
                                                     else
                                                       "#{existing_attributes},#{connection_attributes}"
                                                     end
      end

      def failover_restrictions
        FAILOVER_RESTRICTIONS
      end

      def topology_query
        TOPOLOGY_QUERY
      end

      def host_id(connection)
        @dialect_utils ||= DialectUtils.new
        @dialect_utils.get_instance_id(connection, INSTANCE_ID_QUERY)
      end

      def writer_id_query
        WRITER_ID_QUERY
      end

      def writer_id_column_name
        WRITER_ID_QUERY_COLUMN_NAME
      end
    end
  end
end