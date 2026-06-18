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

module AwsRubyDatabaseDriverWrapper
  module DbDialects
    class UnknownDialect
      DIALECT_UPDATE_CANDIDATES = [
        AwsRubyDatabaseDriverWrapper::DialectCodes::GLOBAL_AURORA_PG,
        AwsRubyDatabaseDriverWrapper::DialectCodes::GLOBAL_AURORA_MYSQL,
        AwsRubyDatabaseDriverWrapper::DialectCodes::AURORA_PG,
        AwsRubyDatabaseDriverWrapper::DialectCodes::AURORA_MYSQL,
        AwsRubyDatabaseDriverWrapper::DialectCodes::MULTI_AZ_PG_CLUSTER,
        AwsRubyDatabaseDriverWrapper::DialectCodes::MULTI_AZ_MYSQL_CLUSTER,
        AwsRubyDatabaseDriverWrapper::DialectCodes::RDS_PG,
        AwsRubyDatabaseDriverWrapper::DialectCodes::RDS_MYSQL,
        AwsRubyDatabaseDriverWrapper::DialectCodes::PG,
        AwsRubyDatabaseDriverWrapper::DialectCodes::MYSQL
      ].freeze

      def initialize(_driver_dialect = nil); end

      def default_port
        @default_port ||= -1
      end

      def host_role(connection)
        raise NotImplementedError, 'Unable to gather host role, connected to unknown DB type.'
      end

      def host_id(connection)
        raise NotImplementedError, 'Unable to gather host id, connected to unknown DB type.'
      end

      def dialect?(_connection)
        false
      end

      def dialect_update_candidates
        DIALECT_UPDATE_CANDIDATES
      end

      def execute(connection, sql)
        raise NotImplementedError, 'Unable to execute query, connected to unknown DB type.'
      end

      # @param service_container [Services::ServiceContainer]
      # @return [Host::ConnectionStringHostListProvider] the host list provider
      def create_host_list_provider(service_container)
        Host::ConnectionStringHostListProvider.new(service_container:)
      end
    end
  end
end
