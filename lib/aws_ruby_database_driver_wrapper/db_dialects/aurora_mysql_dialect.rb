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
    class AuroraMysqlDialect < MysqlDialect
      AURORA_VERSION_EXISTS_QUERY = <<~SQL
        SHOW VARIABLES LIKE 'aurora_version'
      SQL

      TOPOLOGY_QUERY = <<~SQL
        SELECT SERVER_ID AS instance_id,
        CASE WHEN SESSION_ID = 'MASTER_SESSION_ID' THEN TRUE ELSE FALSE END AS is_writer,
        CPU AS cpu_utilization,
        REPLICA_LAG_IN_MILLISECONDS AS instance_lag,
        LAST_UPDATE_TIMESTAMP AS last_update_time
        FROM information_schema.replica_host_status
        WHERE time_to_sec(timediff(now(), LAST_UPDATE_TIMESTAMP)) <= 300 OR SESSION_ID = 'MASTER_SESSION_ID'
      SQL

      # We need to extract ID and instance name. For Aurora they are equivalent, but for multi-az clusters they are not.
      INSTANCE_IDENTITY_QUERY = <<~SQL
        SELECT @@aurora_server_id, @@aurora_server_id
      SQL

      WRITER_ID_QUERY = <<~SQL
        SELECT SERVER_ID FROM information_schema.replica_host_status
        WHERE SESSION_ID = 'MASTER_SESSION_ID' AND SERVER_ID = @@aurora_server_id
      SQL

      IS_READER_QUERY = <<~SQL
        SELECT @@innodb_read_only
      SQL

      BG_TOPOLOGY_EXISTS_QUERY = <<~SQL
        SELECT 1 AS tmp FROM information_schema.tables WHERE
        table_schema = 'mysql' AND table_name = 'rds_topology'
      SQL

      BG_STATUS_QUERY = <<~SQL
        SELECT * FROM mysql.rds_topology
      SQL

      DIALECT_UPDATE_CANDIDATES = [
        AwsRubyDatabaseDriverWrapper::DialectCodes::GLOBAL_AURORA_MYSQL,
        AwsRubyDatabaseDriverWrapper::DialectCodes::MULTI_AZ_MYSQL_CLUSTER
      ].freeze

      def dialect?(connection)
        check_existence_queries(@driver_dialect, connection, AURORA_VERSION_EXISTS_QUERY)
      end

      def dialect_update_candidates
        DIALECT_UPDATE_CANDIDATES
      end

      def instance_identity(connection)
        query_instance_identity(@driver_dialect, connection, INSTANCE_IDENTITY_QUERY)
      end

      def topology_query
        TOPOLOGY_QUERY
      end

      def writer_id_query
        WRITER_ID_QUERY
      end

      def blue_green_status_available?(connection)
        check_existence_queries(@driver_dialect, connection, BG_TOPOLOGY_EXISTS_QUERY)
      end

      def blue_green_status_query
        BG_STATUS_QUERY
      end

      # @param service_container [Services::ServiceContainer]
      # @return [Host::RdsHostListProvider] the host list provider
      def create_host_list_provider(service_container)
        require_relative '../utils/aurora_topology_utils'
        require_relative '../host/rds_host_list_provider'
        topology_utils = Utils::AuroraTopologyUtils.new(dialect: self)
        Host::RdsHostListProvider.new(service_container:, topology_utils:)
      end
    end
  end
end
