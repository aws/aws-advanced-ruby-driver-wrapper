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

require_relative '../driver_dialects/driver_dialect_manager'

module AwsRubyDatabaseDriverWrapper
  module Services
    class DialectService
      attr_reader :driver_dialect

      # @param driver_name [Symbol] :mysql2 or :postgresql
      def initialize(driver_name)
        @driver_dialect = DriverDialects::DriverDialectManager.get_dialect(driver_name)
        @error_handler = DriverDialects::DriverDialectManager.get_error_handler(driver_name)
      end

      # @return [Object] the current database dialect
      def db_dialect
        raise NotImplementedError
      end

      # Resolves the initial database dialect from the connection config.
      # Uses RdsUtils to classify the host (Aurora cluster, RDS instance, etc.)
      # and selects the appropriate dialect.
      #
      # @param connection_config [ConnectionConfig] the connections configuration
      # @return [Object] the resolved database dialect
      def get_dialect(connection_config)
        raise NotImplementedError
      end

      # Refines the dialect after a connection is established by querying the server
      # (e.g. checking for Aurora-specific functions/tables).
      #
      # @param connection [Object] the live database connection
      # @return [Object] the updated database dialect
      def update_dialect(connection)
        raise NotImplementedError
      end

      # @param error [Exception]
      # @return [Boolean]
      def network_error?(error)
        @error_handler.network_error?(error)
      end

      # @param error [Exception]
      # @return [Boolean]
      def login_error?(error)
        @error_handler.login_error?(error)
      end

      # @param error [Exception]
      # @return [Boolean]
      def read_only_error?(error)
        @error_handler.read_only_error?(error)
      end
    end
  end
end
