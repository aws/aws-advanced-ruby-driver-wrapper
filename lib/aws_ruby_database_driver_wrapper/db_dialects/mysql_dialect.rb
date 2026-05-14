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

require_relative './utils/host_role_executor'
require_relative './utils/host_id_executor'
require_relative 'dialect_codes'

module AwsAdvancedRubyWrapper
  module DbDialects
    class MysqlDialect
      include HostRoleExecutor
      include HostIdExecutor

      VERSION_QUERY = <<~SQL.freeze
        SHOW VARIABLES LIKE 'version_comment'
      SQL

      HOST_ID_EXPRESSION = "CONCAT(@@hostname, ':', @@port)"

      HOST_ALIAS_QUERY = <<~SQL.freeze
        SELECT #{HOST_ID_EXPRESSION} AS host_alias
      SQL

      HOST_ID_QUERY = <<~SQL.freeze
        SELECT @@hostname AS host, #{HOST_ID_EXPRESSION} AS host_id
      SQL

      READER_CHECK_QUERY = <<~SQL.freeze
        SELECT @@read_only
      SQL

      DIALECT_UPDATE_CANDIDATES = [
        AwsAdvancedRubyWrapper::DialectCodes::GLOBAL_AURORA_MYSQL,
        AwsAdvancedRubyWrapper::DialectCodes::AURORA_MYSQL,
        AwsAdvancedRubyWrapper::DialectCodes::RDS_MULTI_AZ_MYSQL_CLUSTER,
        AwsAdvancedRubyWrapper::DialectCodes::RDS_MYSQL,
      ].freeze

      def dialect?(connection)
        result = execute(connection, VERSION_QUERY)
        result.any? { |row| row[1]&.downcase&.include?("mysql") }
      rescue StandardError
        false
      end

      def default_port
        @default_port ||= 3306
      end

      def dialect_update_candidates
        DIALECT_UPDATE_CANDIDATES
      end

      def exception_handler(driver_dialect)
        AwsAdvancedRubyWrapper::Errors::MysqlErrorHandler.new(driver_dialect)
      end

      def prepare_connect_properties(connect_properties, protocol, host)
        # do nothing
      end

      def reader_check_query
        READER_CHECK_QUERY
      end

      def host_id_query
        HOST_ID_QUERY
      end

      def host_alias_query
        HOST_ALIAS_QUERY
      end

      def execute(connection, sql)
        connection.exec(sql)
      end
    end
  end
end
