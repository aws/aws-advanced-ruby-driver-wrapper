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

require_relative 'pg_dialect'
require_relative 'utils/dialect_utils'

module AwsRubyDatabaseDriverWrapper
  module DbDialects
    class AuroraPgDialect < PgDialect
      AURORA_UTILS_EXIST_QUERY = <<~SQL
        SELECT (setting LIKE '%aurora_stat_utils%') AS aurora_stat_utils
        FROM pg_catalog.pg_settings
        WHERE name OPERATOR(pg_catalog.=) 'rds.extensions'
      SQL

      TOPOLOGY_EXISTS_QUERY = <<~SQL
        SELECT 1 FROM pg_catalog.aurora_replica_status() LIMIT 1
      SQL

      TOPOLOGY_QUERY = <<~SQL
        SELECT SERVER_ID AS instance_id,
        CASE WHEN SESSION_ID OPERATOR(pg_catalog.=) 'MASTER_SESSION_ID' THEN TRUE ELSE FALSE END AS is_writer,
        CPU AS cpu_utilization,
        COALESCE(REPLICA_LAG_IN_MSEC, 0) AS instance_lag,
        LAST_UPDATE_TIMESTAMP AS last_update_time
        FROM pg_catalog.aurora_replica_status()
        WHERE EXTRACT(EPOCH FROM(pg_catalog.NOW() OPERATOR(pg_catalog.-) LAST_UPDATE_TIMESTAMP)) OPERATOR(pg_catalog.<=) 300
        OR SESSION_ID OPERATOR(pg_catalog.=) 'MASTER_SESSION_ID'
        OR LAST_UPDATE_TIMESTAMP IS NULL
      SQL

      INSTANCE_IDENTITY_QUERY = <<~SQL
        SELECT pg_catalog.aurora_db_instance_identifier() AS instance_name
      SQL

      WRITER_ID_QUERY = <<~SQL
        SELECT SERVER_ID FROM pg_catalog.aurora_replica_status()
        WHERE SESSION_ID OPERATOR(pg_catalog.=) 'MASTER_SESSION_ID'
        AND SERVER_ID OPERATOR(pg_catalog.=) pg_catalog.aurora_db_instance_identifier()
      SQL

      BG_TOPOLOGY_EXISTS_QUERY = <<~SQL
        SELECT 'pg_catalog.get_blue_green_fast_switchover_metadata'::regproc
      SQL

      BG_STATUS_QUERY = <<~SQL
        SELECT * FROM pg_catalog.get_blue_green_fast_switchover_metadata('aws_ruby_database_driver_wrapper-#{AwsRubyDatabaseDriverWrapper::VERSION}')
      SQL

      DIALECT_UPDATE_CANDIDATES = [
        AwsRubyDatabaseDriverWrapper::DialectCodes::GLOBAL_AURORA_PG,
        AwsRubyDatabaseDriverWrapper::DialectCodes::MULTI_AZ_PG_CLUSTER,
        AwsRubyDatabaseDriverWrapper::DialectCodes::RDS_PG
      ].freeze

      def dialect?(connection)
        return false unless super

        begin
          result = @driver_dialect.execute(connection, AURORA_UTILS_EXIST_QUERY)
          return false unless result.any?
          return false unless result.first['aurora_stat_utils'] == 't'
        rescue StandardError
          return false
        end

        result = @driver_dialect.execute(connection, TOPOLOGY_EXISTS_QUERY)
        !result.nil? && result.any?
      rescue StandardError
        false
      end

      def dialect_update_candidates
        DIALECT_UPDATE_CANDIDATES
      end

      def topology_query
        TOPOLOGY_QUERY
      end

      def writer_id_query
        WRITER_ID_QUERY
      end

      def blue_green_status_available?(connection)
        result = @driver_dialect.execute(connection, BG_TOPOLOGY_EXISTS_QUERY)
        !result.nil? && result.any?
      rescue StandardError
        false
      end

      def instance_identity(connection)
        query_instance_identity(@driver_dialect, connection, INSTANCE_IDENTITY_QUERY)
      end

      def blue_green_status_query
        BG_STATUS_QUERY
      end
    end
  end
end
