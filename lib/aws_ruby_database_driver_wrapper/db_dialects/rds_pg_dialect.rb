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
require_relative 'blue_green_dialect'

module AwsAdvancedRubyWrapper
  module DbDialects
    class RdsPgDialect < PgDialect
      include BlueGreenDialect

      EXTENSIONS_EXIST_SQL = <<~SQL.freeze
        SELECT (setting LIKE '%rds_tools%') AS rds_tools,
        (setting LIKE '%aurora_stat_utils%') AS aurora_stat_utils
        FROM pg_catalog.pg_settings
        WHERE name OPERATOR(pg_catalog.=) 'rds.extensions'
      SQL

      TOPOLOGY_TABLE_EXISTS_QUERY = <<~SQL.freeze
        SELECT 'rds_tools.show_topology'::regproc
      SQL

      INSTANCE_ID_QUERY = <<~SQL.freeze
        SELECT id, SUBSTRING(endpoint FROM 0 FOR POSITION('.' IN endpoint))
        FROM rds_tools.show_topology()
        WHERE id OPERATOR(pg_catalog.=) rds_tools.dbi_resource_id()
      SQL

      BG_STATUS_QUERY = <<~SQL.freeze
        SELECT * FROM rds_tools.show_topology('aws_jdbc_driver-#{AwsAdvancedRubyWrapper::VERSION}')
      SQL

      DIALECT_UPDATE_CANDIDATES = [
        AwsAdvancedRubyWrapper::DialectCodes::RDS_MULTI_AZ_PG_CLUSTER,
        AwsAdvancedRubyWrapper::DialectCodes::GLOBAL_AURORA_PG,
        AwsAdvancedRubyWrapper::DialectCodes::AURORA_PG
      ].freeze

      def dialect?(connection)
        return false unless super(connection)

        begin
          result = execute(connection, EXTENSIONS_EXIST_SQL)
          result.each do |row|
            rds_tools = row['rds_tools']
            aurora_utils = row['aurora_stat_utils']

            rds_tools_bool = rds_tools == 't' || rds_tools == true
            aurora_utils_bool = aurora_utils == 't' || aurora_utils == true

            return true if rds_tools_bool && !aurora_utils_bool
          end
        rescue StandardError
          return false
        end

        false
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
