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

require_relative 'mysql2_driver_dialect'
require_relative 'pg_driver_dialect'
require_relative 'trilogy_driver_dialect'
require_relative '../errors'
require_relative '../errors/mysql_error_handler'
require_relative '../errors/pg_error_handler'
require_relative '../errors/trilogy_error_handler'

module AwsAdvancedRubyDriverWrapper
  module DriverDialects
    module DriverDialectManager
      MYSQL2_DIALECT = Mysql2DriverDialect.new.freeze
      PG_DIALECT = PgDriverDialect.new.freeze
      TRILOGY_DIALECT = TrilogyDriverDialect.new.freeze

      REGISTRY = {
        mysql2: {
          driver_dialect: MYSQL2_DIALECT,
          error_handler: Errors::MysqlErrorHandler.new(MYSQL2_DIALECT)
        },
        postgresql: {
          driver_dialect: PG_DIALECT,
          error_handler: Errors::PgErrorHandler.new(PG_DIALECT)
        },
        trilogy: {
          driver_dialect: TRILOGY_DIALECT,
          error_handler: Errors::TrilogyErrorHandler.new(TRILOGY_DIALECT)
        }
      }.freeze

      def self.get_dialect(driver_name)
        fetch_entry(driver_name)[:driver_dialect]
      end

      def self.get_error_handler(driver_name)
        fetch_entry(driver_name)[:error_handler]
      end

      def self.fetch_entry(driver_name)
        REGISTRY.fetch(driver_name) do
          raise Errors::AwsError, "Unknown driver: #{driver_name}"
        end
      end
    end
  end
end
