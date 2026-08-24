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

require_relative 'schema_name'

module AwsRubyDatabaseDriverWrapper
  module Plugins
    module Encryption
      # Checks that the +encryption_metadata+ and +key_storage+ tables exist and look the way the
      # plugin expects before any kms_encryption is attempted.
      #
      # Everything is read from +information_schema+, which both PostgreSQL and MySQL provide, so
      # the same queries work for either driver. Only the foreign key lookup differs: MySQL keeps
      # the referenced table on +key_column_usage+, while PostgreSQL exposes it through
      # +constraint_column_usage+.
      class SchemaValidator
        REQUIRED_ENCRYPTION_METADATA_COLUMNS = %w[
          table_name column_name encryption_algorithm key_id created_at updated_at
        ].freeze

        REQUIRED_KEY_STORAGE_COLUMNS = %w[
          id key_id name master_key_arn encrypted_data_key hmac_key key_spec created_at last_used_at
        ].freeze

        ENCRYPTION_METADATA_TABLE = 'encryption_metadata'
        KEY_STORAGE_TABLE = 'key_storage'
        UNIQUE_METADATA_COLUMNS = %w[table_name column_name].freeze

        # The outcome of a validation run.
        ValidationResult = Data.define(:valid, :issues)

        # Reopened so that the constant below is scoped to the result class.
        class ValidationResult
          def initialize(valid: nil, issues: [])
            frozen_issues = issues.freeze
            super(valid: valid.nil? ? frozen_issues.empty? : valid, issues: frozen_issues)
          end

          # @return [Boolean]
          def valid?
            valid
          end

          def to_s
            valid? ? 'Schema validation passed' : "Schema validation failed: #{issues.join(', ')}"
          end
          alias inspect to_s
        end

        # @param metadata_schema [SchemaName, String] the schema holding the two tables
        # @param sql_runner [SqlRunner]
        def initialize(metadata_schema, sql_runner)
          raise ArgumentError, 'metadata_schema is required' if metadata_schema.nil?

          @schema = SchemaName.of(metadata_schema)
          @sql = sql_runner
        end

        # Validates the schema over an existing connection.
        #
        # @param connection [Object] a pg or mysql2 connection
        # @return [ValidationResult]
        def validate(connection)
          issues = []

          issues.concat(validate_table(connection, ENCRYPTION_METADATA_TABLE, REQUIRED_ENCRYPTION_METADATA_COLUMNS) do
            unique_constraint_issues(connection)
          end)

          issues.concat(validate_table(connection, KEY_STORAGE_TABLE, REQUIRED_KEY_STORAGE_COLUMNS) do
            primary_key_issues(connection)
          end)

          # Only worth checking once both tables are known to be sound.
          issues.concat(foreign_key_issues(connection)) if issues.empty?

          ValidationResult.new(issues: issues)
        end

        private

        # Checks that a table exists and has every required column, then runs the table's own
        # constraint checks.
        def validate_table(connection, table, required_columns)
          qualified = qualify(table)
          return ["Table '#{qualified}' does not exist"] unless table_exists?(connection, table)

          issues = missing_columns(connection, table, required_columns).map do |column|
            "Table '#{qualified}' is missing required column '#{column}'"
          end
          issues.concat(yield)
        end

        def table_exists?(connection, table)
          rows = @sql.query(
            connection,
            'SELECT 1 AS present FROM information_schema.tables WHERE table_schema = ? AND table_name = ?',
            [@schema.to_s, table]
          )
          !rows.empty?
        end

        def missing_columns(connection, table, required_columns)
          rows = @sql.query(
            connection,
            'SELECT column_name AS name FROM information_schema.columns ' \
            'WHERE table_schema = ? AND table_name = ?',
            [@schema.to_s, table]
          )
          existing = rows.to_set { |row| value(row, 'name').to_s.downcase }

          required_columns.reject { |column| existing.include?(column.downcase) }
        end

        def unique_constraint_issues(connection)
          columns = constrained_columns(connection, ENCRYPTION_METADATA_TABLE, ['PRIMARY KEY', 'UNIQUE'])
          expected = UNIQUE_METADATA_COLUMNS.to_set
          return [] if columns.include?(expected)

          ["Table '#{qualify(ENCRYPTION_METADATA_TABLE)}' is missing a unique constraint on " \
           "(#{UNIQUE_METADATA_COLUMNS.join(', ')})"]
        end

        def primary_key_issues(connection)
          columns = constrained_columns(connection, KEY_STORAGE_TABLE, ['PRIMARY KEY'])
          return [] if columns.any? { |constraint_columns| constraint_columns.include?('id') }

          ["Table '#{qualify(KEY_STORAGE_TABLE)}' is missing a primary key on 'id'"]
        end

        def foreign_key_issues(connection)
          references = foreign_keys(connection, ENCRYPTION_METADATA_TABLE)
          matched = references.any? do |reference|
            reference[:from_column] == 'key_id' &&
              reference[:to_table] == KEY_STORAGE_TABLE &&
              reference[:to_column] == 'id'
          end
          return [] if matched

          ["Missing foreign key constraint from #{qualify(ENCRYPTION_METADATA_TABLE)}.key_id " \
           "to #{qualify(KEY_STORAGE_TABLE)}.id"]
        end

        # The column sets of every constraint of the given types, one set per constraint.
        #
        # @return [Array<Set<String>>]
        def constrained_columns(connection, table, constraint_types)
          placeholders = Array.new(constraint_types.size, '?').join(', ')
          rows = @sql.query(
            connection,
            'SELECT tc.constraint_name AS constraint_name, kcu.column_name AS column_name ' \
            'FROM information_schema.table_constraints tc ' \
            'JOIN information_schema.key_column_usage kcu ' \
            'ON tc.constraint_name = kcu.constraint_name AND tc.table_schema = kcu.table_schema ' \
            "AND tc.table_name = kcu.table_name WHERE tc.constraint_type IN (#{placeholders}) " \
            'AND tc.table_schema = ? AND tc.table_name = ?',
            constraint_types + [@schema.to_s, table]
          )

          grouped = rows.group_by { |row| value(row, 'constraint_name') }
          grouped.values.map { |group| group.to_set { |row| value(row, 'column_name').to_s.downcase } }
        end

        # @return [Array<Hash>] one entry per foreign key column of the table
        def foreign_keys(connection, table)
          rows = @sql.query(connection, foreign_key_sql, [@schema.to_s, table])

          rows.map do |row|
            {
              from_column: value(row, 'from_column').to_s.downcase,
              to_table: value(row, 'to_table').to_s.downcase,
              to_column: value(row, 'to_column').to_s.downcase
            }
          end
        end

        def foreign_key_sql
          if @sql.pg?
            'SELECT kcu.column_name AS from_column, ccu.table_name AS to_table, ccu.column_name AS to_column ' \
              'FROM information_schema.table_constraints tc ' \
              'JOIN information_schema.key_column_usage kcu ' \
              'ON tc.constraint_name = kcu.constraint_name AND tc.table_schema = kcu.table_schema ' \
              'JOIN information_schema.constraint_column_usage ccu ' \
              'ON tc.constraint_name = ccu.constraint_name AND tc.table_schema = ccu.table_schema ' \
              "WHERE tc.constraint_type = 'FOREIGN KEY' AND tc.table_schema = ? AND tc.table_name = ?"
          else
            'SELECT column_name AS from_column, referenced_table_name AS to_table, ' \
              'referenced_column_name AS to_column FROM information_schema.key_column_usage ' \
              'WHERE table_schema = ? AND table_name = ? AND referenced_table_name IS NOT NULL'
          end
        end

        # MySQL reports information_schema column names in upper case on some versions, so every
        # lookup accepts either case.
        def value(row, key)
          row[key] || row[key.upcase]
        end

        def qualify(table)
          "#{@schema}.#{table}"
        end
      end
    end
  end
end
