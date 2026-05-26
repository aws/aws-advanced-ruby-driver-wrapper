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
    class RdsMysqlDialect < MysqlDialect
      REPORT_HOST_EXISTS_QUERY = <<~SQL
        SHOW VARIABLES LIKE 'report_host'
      SQL

      TOPOLOGY_TABLE_EXISTS_QUERY = <<~SQL
        SELECT 1 AS tmp FROM information_schema.tables WHERE
        table_schema = 'mysql' AND table_name = 'rds_topology'
      SQL

      INSTANCE_ID_QUERY = <<~SQL
        SELECT SUBSTRING_INDEX(endpoint, '.', 1) AS instance_name
        FROM mysql.rds_topology
        WHERE id = @@server_id
      SQL

      BG_STATUS_QUERY = <<~SQL
        SELECT * FROM mysql.rds_topology
      SQL

      DIALECT_UPDATE_CANDIDATES = [
        AwsRubyDatabaseDriverWrapper::DialectCodes::AURORA_MYSQL,
        AwsRubyDatabaseDriverWrapper::DialectCodes::GLOBAL_AURORA_MYSQL,
        AwsRubyDatabaseDriverWrapper::DialectCodes::MULTI_AZ_MYSQL_CLUSTER
      ].freeze

      def dialect?(connection)
        return false if super

        begin
          result = @driver_dialect.execute(connection, VERSION_QUERY)
          return false unless result.any?

          row = result.first
          column_value = row.values[1]
          return false unless 'Source distribution'.casecmp?(column_value)

          result = @driver_dialect.execute(connection, REPORT_HOST_EXISTS_QUERY)
          return false unless result.any?

          row = result.first
          report_host = row.values[1]
          report_host.nil? || report_host.empty?
        rescue StandardError
          false
        end
      end

      def dialect_update_candidates
        DIALECT_UPDATE_CANDIDATES
      end

      def blue_green_status_available?(connection)
        check_existence_queries(@driver_dialect, connection, TOPOLOGY_TABLE_EXISTS_QUERY)
      end

      def instance_id(connection)
        query_instance_id(@driver_dialect, connection, INSTANCE_ID_QUERY)
      end

      def blue_green_status_query
        BG_STATUS_QUERY
      end
    end
  end
end
