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
    class RdsPgDialect < PgDialect
      EXTENSIONS_EXIST_SQL = <<~SQL
        SELECT (setting LIKE '%rds_tools%') AS rds_tools,
        (setting LIKE '%aurora_stat_utils%') AS aurora_stat_utils
        FROM pg_catalog.pg_settings
        WHERE name OPERATOR(pg_catalog.=) 'rds.extensions'
      SQL

      TOPOLOGY_TABLE_EXISTS_QUERY = <<~SQL
        SELECT 'rds_tools.show_topology'::regproc
      SQL

      INSTANCE_IDENTITY_QUERY = <<~SQL
        SELECT id AS instance_id,
        SUBSTRING(endpoint FROM 0 FOR POSITION('.' IN endpoint)) AS instance_name
        FROM rds_tools.show_topology()
        WHERE id OPERATOR(pg_catalog.=) rds_tools.dbi_resource_id()
      SQL

      BG_STATUS_QUERY = <<~SQL
        SELECT * FROM rds_tools.show_topology('aws_ruby_database_driver_wrapper-#{AwsRubyDatabaseDriverWrapper::VERSION}')
      SQL

      DIALECT_UPDATE_CANDIDATES = [
        AwsRubyDatabaseDriverWrapper::DialectCodes::MULTI_AZ_PG_CLUSTER,
        AwsRubyDatabaseDriverWrapper::DialectCodes::GLOBAL_AURORA_PG,
        AwsRubyDatabaseDriverWrapper::DialectCodes::AURORA_PG
      ].freeze

      def dialect?(connection)
        return false unless super

        begin
          result = @driver_dialect.execute(connection, EXTENSIONS_EXIST_SQL)
          result.each do |row|
            rds_tools_enabled = row['rds_tools'] == 't'
            aurora_utils_enabled = row['aurora_stat_utils'] == 't'

            return true if rds_tools_enabled && !aurora_utils_enabled
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
        check_existence_queries(@driver_dialect, connection, TOPOLOGY_TABLE_EXISTS_QUERY)
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
