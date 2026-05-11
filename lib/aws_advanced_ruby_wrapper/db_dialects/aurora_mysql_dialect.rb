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

module AwsAdvancedRubyWrapper
  module DbDialects
    class AuroraMysqlDialect
      TOPOLOGY_QUERY = <<~SQL
        SELECT SERVER_ID AS host_id,
               SESSION_ID = 'MASTER_SESSION_ID' AS is_writer,
               CPU AS cpu_utilization,
               REPLICA_LAG_IN_MILLISECONDS AS instance_lag,
               LAST_UPDATE_TIMESTAMP AS last_update_time
        FROM information_schema.replica_host_status
        -- filter out instances that haven't been updated in the last 5 minutes
        WHERE time_to_sec(timediff(now(), LAST_UPDATE_TIMESTAMP)) <= 300
            OR SESSION_ID = 'MASTER_SESSION_ID'
      SQL

      def execute(conn, sql)
        conn.query(sql)
      end
    end
  end
end
