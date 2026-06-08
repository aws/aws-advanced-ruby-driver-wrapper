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
require_relative 'utils/dialect_utils'

module AwsRubyDatabaseDriverWrapper
  module DbDialects
    class MultiAzClusterMysqlDialect < MysqlDialect
      REPORT_HOST_EXISTS_QUERY = <<~SQL
        SHOW VARIABLES LIKE 'report_host'
      SQL

      TOPOLOGY_TABLE_EXISTS_QUERY = <<~SQL
        SELECT 1 AS tmp FROM information_schema.tables WHERE
        table_schema = 'mysql' AND table_name = 'rds_topology'
      SQL

      TOPOLOGY_QUERY = <<~SQL
        SELECT id AS instance_id, endpoint AS endpoint FROM mysql.rds_topology
      SQL

      INSTANCE_IDENTITY_QUERY = <<~SQL
        SELECT id AS instance_id,
        SUBSTRING_INDEX(endpoint, '.', 1) AS instance_name
        FROM mysql.rds_topology
        WHERE id = @@server_id
      SQL

      WRITER_ID_QUERY = <<~SQL
        SHOW REPLICA STATUS
      SQL

      WRITER_ID_QUERY_COLUMN_NAME = 'Source_Server_Id'

      def dialect?(connection)
        return false unless
          check_existence_queries(@driver_dialect, connection, TOPOLOGY_TABLE_EXISTS_QUERY, TOPOLOGY_QUERY)

        begin
          result = @driver_dialect.execute(connection, REPORT_HOST_EXISTS_QUERY)
          return false if result.none?

          row = result.first
          report_host = row.values[1]
          report_host.is_a?(String) && !report_host.empty?
        rescue StandardError
          false
        end
      end

      def dialect_update_candidates
        []
      end

      def topology_query
        TOPOLOGY_QUERY
      end

      def instance_identity(connection)
        query_instance_identity(@driver_dialect, connection, INSTANCE_IDENTITY_QUERY)
      end

      def writer_id_query
        WRITER_ID_QUERY
      end

      def writer_id_column_name
        WRITER_ID_QUERY_COLUMN_NAME
      end

      # @param service_container [Services::ServiceContainer]
      # @return [Host::RdsHostListProvider] the host list provider
      def create_host_list_provider(service_container)
        require_relative '../utils/multi_az_topology_utils'
        require_relative '../host/rds_host_list_provider'
        topology_utils = Utils::MultiAzTopologyUtils.new(dialect: self)
        Host::RdsHostListProvider.new(service_container: service_container, topology_utils: topology_utils)
      end
    end
  end
end
