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
require_relative 'topology_dialect'
require_relative 'blue_green_dialect'

module AwsAdvancedRubyWrapper
  module DbDialects
    class AuroraMysqlDialect < MysqlDialect
      include TopologyAwareDialect
      include BlueGreenDialect

      AURORA_VERSION_EXISTS_QUERY = <<~SQL.freeze
        SHOW VARIABLES LIKE 'aurora_version'
      SQL

      TOPOLOGY_QUERY = <<~SQL.freeze
        SELECT SERVER_ID, CASE WHEN SESSION_ID = 'MASTER_SESSION_ID' THEN TRUE ELSE FALSE END,
        CPU, REPLICA_LAG_IN_MILLISECONDS, LAST_UPDATE_TIMESTAMP
        FROM information_schema.replica_host_status
        WHERE time_to_sec(timediff(now(), LAST_UPDATE_TIMESTAMP)) <= 300 OR SESSION_ID = 'MASTER_SESSION_ID'
      SQL

      INSTANCE_ID_QUERY = <<~SQL.freeze
        SELECT @@aurora_server_id, @@aurora_server_id
      SQL

      WRITER_ID_QUERY = <<~SQL.freeze
        SELECT SERVER_ID FROM information_schema.replica_host_status
        WHERE SESSION_ID = 'MASTER_SESSION_ID' AND SERVER_ID = @@aurora_server_id
      SQL

      READER_CHECK_QUERY = <<~SQL.freeze
        SELECT @@innodb_read_only
      SQL

      BG_TOPOLOGY_EXISTS_QUERY = <<~SQL.freeze
        SELECT 1 AS tmp FROM information_schema.tables WHERE
        table_schema = 'mysql' AND table_name = 'rds_topology'
      SQL

      BG_STATUS_QUERY = <<~SQL.freeze
        SELECT * FROM mysql.rds_topology
      SQL

      DIALECT_UPDATE_CANDIDATES = [
        AwsAdvancedRubyWrapper::DialectCodes::GLOBAL_AURORA_MYSQL,
        AwsAdvancedRubyWrapper::DialectCodes::RDS_MULTI_AZ_MYSQL_CLUSTER
      ].freeze

      def dialect?(connection)
        result = execute(connection, AURORA_VERSION_EXISTS_QUERY)
        !result.nil? && result.any?
      rescue StandardError
        false
      end

      def dialect_update_candidates
        DIALECT_UPDATE_CANDIDATES
      end

      def reader_check_query
        READER_CHECK_QUERY
      end

      def host_id_query
        INSTANCE_ID_QUERY
      end

      def topology_query
        TOPOLOGY_QUERY
      end

      def writer_id_query
        WRITER_ID_QUERY
      end

      def blue_green_status_available?(connection)
        result = execute(connection, BG_TOPOLOGY_EXISTS_QUERY)
        !result.nil? && result.any?
      rescue StandardError
        false
      end

      def blue_green_status_query
        BG_STATUS_QUERY
      end
    end
  end
end
