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

require_relative '../ruby_method'
require_relative '../logging'

module AwsRubyDatabaseDriverWrapper
  module DriverDialects
    module DriverDialect
      include Logging

      COMMON_NETWORK_BOUND_METHODS = Set[
        RubyMethod::CONNECT.name,
        RubyMethod::CONNECTION_CLOSE.name,
        RubyMethod::CONNECTION_RESET.name,
        RubyMethod::CONNECTION_PREPARE.name,
        RubyMethod::STATEMENT_EXECUTE.name,
        RubyMethod::STATEMENT_CLOSE.name
      ].freeze

      DEFAULT_MONITORING_TIMEOUT_SEC = 5

      def connect(host_info, config)
        raise NotImplementedError
      end

      def execute(connection, sql)
        raise NotImplementedError
      end

      def execute_with_params(connection, sql, params)
        raise NotImplementedError
      end

      # Rewrites +?+ placeholders into the driver's native placeholder syntax.
      # @param sql [String] SQL written with +?+ placeholders
      # @return [String]
      def translate_placeholders(sql)
        raise NotImplementedError
      end

      # Wraps binary data as the bind value the driver needs for a bytea/blob parameter.
      # @param bytes [String] binary data
      # @return [Object] the driver-specific bind value
      def binary_param(bytes)
        raise NotImplementedError
      end

      # Reads a bytea/blob column value back into binary data.
      # @param value [String] the raw column value
      # @return [String] binary data
      def read_binary(value)
        raise NotImplementedError
      end

      # The number of rows an INSERT, UPDATE, or DELETE changed.
      # @param connection [Object] the driver connection
      # @param result [Object] the value the statement returned
      # @return [Integer]
      def affected_rows(connection, result)
        raise NotImplementedError
      end

      # Runs an INSERT and returns the id it generated.
      # @param sql [String] native SQL for the INSERT, without a RETURNING clause
      # @param id_column [String] the generated column to return
      # @return [Integer, nil]
      def insert_returning_id(connection, sql, params, id_column)
        raise NotImplementedError
      end

      # The trailing upsert clause for an INSERT, in the driver's own grammar.
      # @param conflict_columns [Array<String>] the columns whose conflict triggers the update
      # @param update_columns [Array<String>] the columns to overwrite from the incoming row
      # @return [String]
      def upsert_clause(conflict_columns, update_columns)
        raise NotImplementedError
      end

      # A query returning a table's foreign keys as rows with +from_column+, +to_table+, and
      # +to_column+, using +?+ placeholders for the schema and table names.
      # @return [String]
      def foreign_key_query
        raise NotImplementedError
      end

      def ping(connection)
        raise NotImplementedError
      end

      def closed?(connection)
        raise NotImplementedError
      end

      def close_connection(connection)
        raise NotImplementedError
      end

      def sql_state(_exception)
        nil
      end

      def network_bound_methods
        COMMON_NETWORK_BOUND_METHODS
      end

      def prepare_connect_config(host_info, config)
        raise NotImplementedError
      end

      # Returns the property key the underlying driver expects for the database username.
      # Override in driver-specific dialects where the key differs.
      def user_property_key
        :user
      end

      # Applies default socket/connect timeouts to monitoring connection driver props.
      # These ensure that a query or close on a dead connection raises a timeout error
      # rather than hanging indefinitely or segfaulting.
      # Implementations should only apply these properties if the user hasn't already set them.
      # @param driver_props [Hash] the monitoring connection driver props (mutated in place)
      def apply_monitoring_defaults(driver_props)
        # No-op by default; driver-specific dialects override.
      end
    end
  end
end
