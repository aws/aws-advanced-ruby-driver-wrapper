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

require_relative 'dialect_codes'
require_relative 'utils/dialect_utils'

module AwsRubyDatabaseDriverWrapper
  module DbDialects
    class MysqlDialect
      include AwsRubyDatabaseDriverWrapper::DbDialects::DialectUtils

      VERSION_QUERY = <<~SQL
        SHOW VARIABLES LIKE 'version_comment'
      SQL

      INSTANCE_IDENTITY_QUERY = <<~SQL
        SELECT @@hostname AS instance_id, CONCAT(@@hostname, ':', @@port) AS instance_name
      SQL

      READER_CHECK_QUERY = <<~SQL
        SELECT @@read_only
      SQL

      DIALECT_UPDATE_CANDIDATES = [
        AwsRubyDatabaseDriverWrapper::DialectCodes::GLOBAL_AURORA_MYSQL,
        AwsRubyDatabaseDriverWrapper::DialectCodes::AURORA_MYSQL,
        AwsRubyDatabaseDriverWrapper::DialectCodes::MULTI_AZ_MYSQL_CLUSTER,
        AwsRubyDatabaseDriverWrapper::DialectCodes::RDS_MYSQL
      ].freeze

      def initialize(driver_dialect)
        @driver_dialect = driver_dialect
      end

      def execute(connection, sql)
        @driver_dialect.execute(connection, sql)
      end

      def dialect?(connection)
        result = @driver_dialect.execute(connection, VERSION_QUERY)
        result.any? do |row|
          row.values[1]&.downcase&.include?('mysql')
        end
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
        AwsRubyDatabaseDriverWrapper::Errors::MysqlErrorHandler.new(driver_dialect)
      end

      def host_role(connection)
        query_host_role(@driver_dialect, connection, READER_CHECK_QUERY)
      end

      def instance_identity(connection)
        query_instance_identity(@driver_dialect, connection, INSTANCE_IDENTITY_QUERY)
      end

      # @param _service_container [Services::ServiceContainer]
      # @return [Host::ConnectionStringHostListProvider] the host list provider
      def create_host_list_provider(_service_container)
        # TODO: return ConnectionStringHostListProvider
        nil
      end
    end
  end
end
