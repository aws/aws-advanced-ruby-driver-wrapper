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

require_relative '../../driver_dialects/pg_driver_dialect'

module AwsAdvancedRubyDriverWrapper
  module Plugins
    module Encryption
      # Runs the plugin's own metadata and key storage queries against either driver.
      #
      # The plugin needs to talk to +encryption_metadata+ and +key_storage+ itself, and the two
      # drivers disagree on almost every detail of how to do that: pg wants +$1+ placeholders
      # and hex escaped bytea, mysql2 wants +?+ placeholders and raw binary, and only pg can
      # return a generated id from an INSERT. This isolates those differences so that the
      # managers above it can be written once.
      #
      # SQL is always written with +?+ placeholders and translated here.
      class SqlRunner
        # @param driver_dialect [DriverDialects::DriverDialect] the dialect of the connection in use
        def initialize(driver_dialect)
          @driver_dialect = driver_dialect
          @pg = driver_dialect.is_a?(DriverDialects::PgDriverDialect)
        end

        # @return [Boolean] true when the underlying driver is pg
        def pg?
          @pg
        end

        # Runs a query and returns its rows.
        #
        # @param connection [Object] a pg or mysql2 connection
        # @param template [String] SQL using +?+ placeholders
        # @param params [Array] the bind parameters
        # @return [Array<Hash{String => Object}>] the result rows, empty for statements without one
        def query(connection, template, params = [])
          rows(raw_execute(connection, template, params))
        end
        alias execute query

        # Runs an INSERT, UPDATE, or DELETE and returns how many rows it changed.
        #
        # @param connection [Object] a pg or mysql2 connection
        # @param template [String] SQL using +?+ placeholders
        # @param params [Array] the bind parameters
        # @return [Integer] the number of affected rows
        def update(connection, template, params = [])
          result = raw_execute(connection, template, params)
          @driver_dialect.affected_rows(connection, result)
        end

        # Runs an INSERT and returns the generated +id+.
        #
        # @param connection [Object] a pg or mysql2 connection
        # @param template [String] an INSERT using +?+ placeholders, without a RETURNING clause
        # @param params [Array] the bind parameters
        # @param id_column [String] the generated column to return
        # @return [Integer, nil] the generated id
        def insert_returning_id(connection, template, params, id_column: 'id')
          @driver_dialect.insert_returning_id(connection, translate(template), params, id_column)
        end

        # Wraps a binary value so that it can be bound to a bytea or blob parameter.
        #
        # @param bytes [String, nil] binary data
        # @return [Object, nil] the driver specific bind value
        def binary_param(bytes)
          return nil if bytes.nil?

          @driver_dialect.binary_param(bytes)
        end

        # Reads a bytea or blob column back into binary data.
        #
        # @param value [String, nil] the raw column value
        # @return [String, nil] binary data
        def read_binary(value)
          return nil if value.nil?

          @driver_dialect.read_binary(value)
        end

        # Translates +?+ placeholders into the driver's own placeholder syntax.
        #
        # @param template [String]
        # @return [String]
        def translate(template)
          @driver_dialect.translate_placeholders(template)
        end

        # The driver-specific trailing upsert clause for an INSERT.
        #
        # @param conflict_columns [Array<String>] the columns whose conflict triggers the update
        # @param update_columns [Array<String>] the columns to overwrite from the incoming row
        # @return [String]
        def upsert_clause(conflict_columns, update_columns)
          @driver_dialect.upsert_clause(conflict_columns, update_columns)
        end

        # The driver-specific equality operator. Every comparison in the plugin's own SQL uses it,
        # so that on pg a user-defined operator earlier in the search_path cannot take its place.
        #
        # @return [String]
        def equals_operator
          @driver_dialect.equals_operator
        end

        # The driver-specific query for a table's foreign keys, using +?+ placeholders for the
        # schema and table names.
        #
        # @return [String]
        def foreign_key_query
          @driver_dialect.foreign_key_query
        end

        private

        def raw_execute(connection, template, params)
          if params.empty?
            @driver_dialect.execute(connection, translate(template))
          else
            @driver_dialect.execute_with_params(connection, translate(template), params)
          end
        end

        def rows(result)
          return [] if result.nil? || !result.respond_to?(:each)

          result.to_a
        end
      end
    end
  end
end
