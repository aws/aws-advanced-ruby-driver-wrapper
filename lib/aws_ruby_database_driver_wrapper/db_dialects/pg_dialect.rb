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
require_relative '../host/connection_string_host_list_provider'

module AwsRubyDatabaseDriverWrapper
  module DbDialects
    class PgDialect
      include AwsRubyDatabaseDriverWrapper::DbDialects::DialectUtils

      PG_PROC_EXISTS_QUERY = <<~SQL
        SELECT 1 FROM pg_catalog.pg_proc LIMIT 1
      SQL

      INSTANCE_IDENTITY_QUERY = <<~SQL
        SELECT pg_catalog.inet_server_addr() AS instance_id,
        pg_catalog.CONCAT(pg_catalog.inet_server_addr(), ':', pg_catalog.inet_server_port()) AS instance_name
      SQL

      IS_READER_QUERY = <<~SQL
        SELECT pg_catalog.pg_is_in_recovery()
      SQL

      DIALECT_UPDATE_CANDIDATES = [
        AwsRubyDatabaseDriverWrapper::DialectCodes::GLOBAL_AURORA_PG,
        AwsRubyDatabaseDriverWrapper::DialectCodes::AURORA_PG,
        AwsRubyDatabaseDriverWrapper::DialectCodes::MULTI_AZ_PG_CLUSTER,
        AwsRubyDatabaseDriverWrapper::DialectCodes::RDS_PG
      ].freeze

      def initialize(driver_dialect)
        @driver_dialect = driver_dialect
      end

      def execute(connection, sql)
        @driver_dialect.execute(connection, sql)
      end

      def execute_with_params(connection, sql, params)
        @driver_dialect.execute_with_params(connection, sql, params)
      end

      def dialect?(connection)
        check_existence_queries(@driver_dialect, connection, PG_PROC_EXISTS_QUERY)
      end

      def default_port
        @default_port ||= 5432
      end

      def dialect_update_candidates
        DIALECT_UPDATE_CANDIDATES
      end

      def exception_handler(driver_dialect)
        AwsRubyDatabaseDriverWrapper::Errors::PgErrorHandler.new(driver_dialect)
      end

      def host_role(connection)
        query_host_role(@driver_dialect, connection, IS_READER_QUERY)
      end

      def instance_identity(connection)
        query_instance_identity(@driver_dialect, connection, INSTANCE_IDENTITY_QUERY)
      end

      # @param service_container [Services::ServiceContainer]
      # @return [Host::ConnectionStringHostListProvider] the host list provider
      def create_host_list_provider(service_container)
        Host::ConnectionStringHostListProvider.new(service_container:)
      end
    end
  end
end
