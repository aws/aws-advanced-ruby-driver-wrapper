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
require_relative 'blue_green_dialect'

module AwsAdvancedRubyWrapper
  module DbDialects
    class RdsMysqlDialect < MysqlDialect
      include BlueGreenDialect

      REPORT_HOST_EXISTS_QUERY = <<~SQL.freeze
        SHOW VARIABLES LIKE 'report_host'
      SQL

      TOPOLOGY_TABLE_EXISTS_QUERY = <<~SQL.freeze
        SELECT 1 AS tmp FROM information_schema.tables WHERE
        table_schema = 'mysql' AND table_name = 'rds_topology'
      SQL

      INSTANCE_ID_QUERY = <<~SQL.freeze
        SELECT id, SUBSTRING_INDEX(endpoint, '.', 1)
        FROM mysql.rds_topology
        WHERE id = @@server_id
      SQL

      BG_STATUS_QUERY = <<~SQL.freeze
        SELECT * FROM mysql.rds_topology
      SQL

      DIALECT_UPDATE_CANDIDATES = [
        AwsAdvancedRubyWrapper::DialectCodes::AURORA_MYSQL,
        AwsAdvancedRubyWrapper::DialectCodes::GLOBAL_AURORA_MYSQL,
        AwsAdvancedRubyWrapper::DialectCodes::RDS_MULTI_AZ_MYSQL_CLUSTER
      ].freeze

      def dialect?(connection)
        if super(connection)
          return false
        end

        begin
          result = execute(connection, VERSION_QUERY)
          return false unless result.any?

          row = result.first
          column_value = row.is_a?(Hash) ? row.values[1] : row[1]
          return false unless "Source distribution".casecmp?(column_value)

          result = execute(connection, REPORT_HOST_EXISTS_QUERY)
          return false unless result.any?

          row = result.first
          report_host = row.is_a?(Hash) ? row.values[1] : row[1]
          return report_host.nil? || report_host.empty?

        rescue StandardError
          return false
        end
      end

      def dialect_update_candidates
        DIALECT_UPDATE_CANDIDATES
      end

      def blue_green_status_available?(connection)
        result = execute(connection, TOPOLOGY_TABLE_EXISTS_QUERY)
        !result.nil? && result.any?
      rescue StandardError
        false
      end

      def host_id_query
        INSTANCE_ID_QUERY
      end

      def blue_green_status_query
        BG_STATUS_QUERY
      end
    end
  end
end
