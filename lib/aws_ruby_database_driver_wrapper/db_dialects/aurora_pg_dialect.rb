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

module AwsRubyDatabaseDriverWrapper
  module DbDialects
    class AuroraPgDialect
      TOPOLOGY_QUERY = <<~SQL
        SELECT SERVER_ID AS host_id,
               SESSION_ID OPERATOR(pg_catalog.=) 'MASTER_SESSION_ID' AS is_writer,
               CPU AS cpu_utilization,
               COALESCE(REPLICA_LAG_IN_MSEC, 0) AS instance_lag,
               LAST_UPDATE_TIMESTAMP AS last_update_time
        FROM pg_catalog.aurora_replica_status()
        -- filter out instances that haven't been updated in the last 5 minutes
        WHERE EXTRACT(EPOCH FROM (pg_catalog.NOW() OPERATOR(pg_catalog.-) LAST_UPDATE_TIMESTAMP)) OPERATOR(pg_catalog.<=) 300
            OR SESSION_ID OPERATOR(pg_catalog.=) 'MASTER_SESSION_ID'
            OR LAST_UPDATE_TIMESTAMP IS NULL
      SQL

      def execute(conn, sql)
        conn.exec(sql)
      end
    end
  end
end
