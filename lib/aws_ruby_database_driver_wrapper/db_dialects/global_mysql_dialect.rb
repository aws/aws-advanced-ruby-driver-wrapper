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

require_relative 'aurora_mysql_dialect'
require_relative 'utils/dialect_utils'

module AwsRubyDatabaseDriverWrapper
  module DbDialects
    class GlobalMysqlDialect < AuroraMysqlDialect
      GLOBAL_STATUS_TABLE_EXISTS_QUERY = <<~SQL
        SELECT 1 AS tmp FROM information_schema.tables WHERE
        upper(table_schema) = 'INFORMATION_SCHEMA' AND upper(table_name) = 'AURORA_GLOBAL_DB_STATUS'
      SQL

      GLOBAL_INSTANCE_STATUS_EXISTS_QUERY = <<~SQL
        SELECT 1 AS tmp FROM information_schema.tables WHERE
        upper(table_schema) = 'INFORMATION_SCHEMA' AND upper(table_name) = 'AURORA_GLOBAL_DB_INSTANCE_STATUS'
      SQL

      GLOBAL_TOPOLOGY_QUERY = <<~SQL
        SELECT SERVER_ID AS instance_id,
        CASE WHEN SESSION_ID = 'MASTER_SESSION_ID' THEN TRUE ELSE FALSE END AS is_writer,
        VISIBILITY_LAG_IN_MSEC AS instance_lag,
        AWS_REGION AS aws_region
        FROM information_schema.aurora_global_db_instance_status
      SQL

      REGION_COUNT_QUERY = <<~SQL
        SELECT count(1) FROM information_schema.aurora_global_db_status
      SQL

      REGION_BY_INSTANCE_ID_QUERY = <<~SQL
        SELECT AWS_REGION FROM information_schema.aurora_global_db_instance_status WHERE SERVER_ID = ?
      SQL

      def dialect?(connection)
        return false unless
          check_existence_queries(@driver_dialect, connection, GLOBAL_STATUS_TABLE_EXISTS_QUERY, GLOBAL_INSTANCE_STATUS_EXISTS_QUERY)

        begin
          result = @driver_dialect.execute(connection, REGION_COUNT_QUERY)
          return false unless result.any?

          row = result.first
          aws_region_count = row.values.first.to_i
          aws_region_count > 1
        rescue StandardError
          false
        end
      end

      def dialect_update_candidates
        []
      end

      def topology_query
        GLOBAL_TOPOLOGY_QUERY
      end

      def region_by_instance_id_query
        REGION_BY_INSTANCE_ID_QUERY
      end

      # @param service_container [Services::ServiceContainer]
      # @return [Host::GlobalAuroraHostListProvider] the host list provider
      def create_host_list_provider(service_container)
        require_relative '../utils/global_aurora_topology_utils'
        require_relative '../host/global_aurora_host_list_provider'
        topology_utils = Utils::GlobalAuroraTopologyUtils.new(dialect: self)
        Host::GlobalAuroraHostListProvider.new(service_container:, topology_utils:)
      end
    end
  end
end
