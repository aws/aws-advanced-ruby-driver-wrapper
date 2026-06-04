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

require_relative 'aurora_pg_dialect'
require_relative 'utils/dialect_utils'

module AwsRubyDatabaseDriverWrapper
  module DbDialects
    class GlobalPgDialect < AuroraPgDialect
      GLOBAL_STATUS_FUNC_EXISTS_QUERY = <<~SQL
        SELECT 'aurora_global_db_status'::regproc
      SQL

      GLOBAL_INSTANCE_STATUS_FUNC_EXISTS_QUERY = <<~SQL
        SELECT 'aurora_global_db_instance_status'::regproc
      SQL

      GLOBAL_TOPOLOGY_QUERY = <<~SQL
        SELECT SERVER_ID, CASE WHEN SESSION_ID = 'MASTER_SESSION_ID' THEN TRUE ELSE FALSE END,
        VISIBILITY_LAG_IN_MSEC, AWS_REGION
        FROM aurora_global_db_instance_status()
      SQL

      REGION_COUNT_QUERY = <<~SQL
        SELECT count(1) FROM aurora_global_db_status()
      SQL

      REGION_BY_INSTANCE_ID_QUERY = <<~SQL
        SELECT AWS_REGION FROM aurora_global_db_instance_status() WHERE SERVER_ID = $1
      SQL

      def dialect?(connection)
        result = @driver_dialect.execute(connection, AURORA_UTILS_EXIST_QUERY)
        return false unless result.any?

        return false unless result.first['aurora_stat_utils'] == 't'

        return false unless
          check_existence_queries(@driver_dialect, connection, GLOBAL_STATUS_FUNC_EXISTS_QUERY, GLOBAL_INSTANCE_STATUS_FUNC_EXISTS_QUERY)

        result = connection.exec(REGION_COUNT_QUERY)
        return false unless result.any?

        row = result.first
        aws_region_count = row.is_a?(Hash) ? row.values.first.to_i : row[0].to_i
        aws_region_count > 1
      rescue StandardError
        false
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

      # @param _service_container [Services::ServiceContainer]
      # @return [Host::GlobalAuroraHostListProvider] the host list provider
      def create_host_list_provider(_service_container)
        # TODO: return GlobalAuroraHostListProvider
        nil
      end
    end
  end
end
