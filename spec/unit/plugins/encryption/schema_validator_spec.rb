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

require_relative '../../../spec_helper'
require 'aws_advanced_ruby_driver_wrapper/plugins/kms_encryption/schema_validator'
require 'aws_advanced_ruby_driver_wrapper/plugins/kms_encryption/sql_runner'
require 'aws_advanced_ruby_driver_wrapper/driver_dialects/pg_driver_dialect'
require 'aws_advanced_ruby_driver_wrapper/driver_dialects/mysql_driver_dialect'

RSpec.describe AwsAdvancedRubyDriverWrapper::Plugins::Encryption::SchemaValidator do
  let(:encryption) { AwsAdvancedRubyDriverWrapper::Plugins::Encryption }
  let(:sql_runner) { instance_double(encryption::SqlRunner, pg?: true, equals_operator: 'OPERATOR(pg_catalog.=)') }
  let(:connection) { double('Connection') }
  # What a correctly created schema looks like: both tables exist with all their columns, the
  # metadata table is unique on (table_name, column_name) and points at key_storage.id.
  let(:tables) { %w[encryption_metadata key_storage] }
  let(:columns) do
    { 'encryption_metadata' => described_class::REQUIRED_ENCRYPTION_METADATA_COLUMNS,
      'key_storage' => described_class::REQUIRED_KEY_STORAGE_COLUMNS }
  end
  let(:constraints) do
    { 'encryption_metadata' => { 'encryption_metadata_table_name_column_name_key' => %w[table_name column_name] },
      'key_storage' => { 'key_storage_pkey' => ['id'] } }
  end
  let(:foreign_keys) do
    { 'encryption_metadata' => [{ from: 'key_id', to_table: 'key_storage', to_column: 'id' }] }
  end
  # The foreign-key query now comes from the driver dialect; build the real ones so the stub stays
  # in step with what the dialects actually produce.
  let(:pg_foreign_key_sql) { AwsAdvancedRubyDriverWrapper::DriverDialects::PgDriverDialect.new.foreign_key_query }
  let(:mysql_foreign_key_sql) { AwsAdvancedRubyDriverWrapper::DriverDialects::MysqlDriverDialect.new.foreign_key_query }
  subject(:validator) { described_class.new('encrypt', sql_runner) }

  # information_schema is queried for four different things, so the runner answers by SQL shape.
  before do
    allow(sql_runner).to receive(:foreign_key_query).and_return(pg_foreign_key_sql)
    allow(sql_runner).to receive(:query) do |_connection, sql, params|
      table = params.last
      case sql
      when /information_schema\.tables/ then tables.include?(table) ? [{ 'present' => 1 }] : []
      when /information_schema\.columns/ then columns.fetch(table, []).map { |name| { 'name' => name } }
      when /FOREIGN KEY|referenced_table_name/ then foreign_key_rows(table)
      else constraint_rows(table)
      end
    end
  end

  def constraint_rows(table)
    constraints.fetch(table, {}).flat_map do |name, constraint_columns|
      constraint_columns.map { |column| { 'constraint_name' => name, 'column_name' => column } }
    end
  end

  def foreign_key_rows(table)
    foreign_keys.fetch(table, []).map do |reference|
      { 'from_column' => reference[:from], 'to_table' => reference[:to_table], 'to_column' => reference[:to_column] }
    end
  end

  it 'needs a schema to look in' do
    expect { described_class.new(nil, sql_runner) }.to raise_error(ArgumentError, /metadata_schema is required/)
  end

  it 'rejects a schema name that could not be used safely in a query' do
    expect { described_class.new('encrypt;DROP TABLE users', sql_runner) }
      .to raise_error(ArgumentError, /Invalid schema name/)
  end

  describe 'a correctly created schema' do
    it 'passes' do
      result = validator.validate(connection)

      expect(result).to be_valid
      expect(result.issues).to be_empty
      expect(result.to_s).to eq('Schema validation passed')
    end

    # Both engines expose information_schema, and MySQL reports its column names in upper case on
    # some versions.
    it 'passes for a MySQL schema that reports upper case column names' do
      allow(sql_runner).to receive(:pg?).and_return(false)
      allow(sql_runner).to receive(:foreign_key_query).and_return(mysql_foreign_key_sql)
      allow(sql_runner).to receive(:query) do |_connection, sql, params|
        table = params.last
        case sql
        when /information_schema\.tables/ then [{ 'present' => 1 }]
        when /information_schema\.columns/ then columns.fetch(table, []).map { |name| { 'NAME' => name.upcase } }
        when /FOREIGN KEY|referenced_table_name/
          foreign_key_rows(table).map { |row| row.transform_keys(&:upcase) }
        else
          constraint_rows(table).map { |row| row.transform_keys(&:upcase) }
        end
      end

      expect(validator.validate(connection)).to be_valid
    end

    # MySQL keeps the referenced table on key_column_usage, PostgreSQL on constraint_column_usage.
    it 'asks MySQL for the referenced table the way MySQL exposes it' do
      allow(sql_runner).to receive(:pg?).and_return(false)
      allow(sql_runner).to receive(:foreign_key_query).and_return(mysql_foreign_key_sql)
      validator.validate(connection)

      expect(sql_runner).to have_received(:query).with(connection, /referenced_table_name IS NOT NULL/, any_args)
    end

    it 'asks PostgreSQL for the referenced table the way PostgreSQL exposes it' do
      validator.validate(connection)
      expect(sql_runner).to have_received(:query).with(connection, /constraint_column_usage ccu/, any_args)
    end

    # IN compares with an unqualified operator too, so it must not appear either.
    it 'compares only with the driver equality operator' do
      validator.validate(connection)
      expect(sql_runner).to have_received(:query).at_least(:once)
      expect(sql_runner).not_to have_received(:query).with(connection, / = | IN \(/, any_args)
    end

    it 'matches every requested constraint type' do
      validator.validate(connection)
      expect(sql_runner).to have_received(:query).with(
        connection,
        /\(tc\.constraint_type OPERATOR\(pg_catalog\.=\) \? OR tc\.constraint_type OPERATOR\(pg_catalog\.=\) \?\)/,
        ['PRIMARY KEY', 'UNIQUE', 'encrypt', 'encryption_metadata']
      )
    end
  end

  describe 'a schema that was never created' do
    let(:tables) { [] }

    it 'reports both missing tables' do
      result = validator.validate(connection)

      expect(result).not_to be_valid
      expect(result.issues).to contain_exactly("Table 'encrypt.encryption_metadata' does not exist",
                                               "Table 'encrypt.key_storage' does not exist")
      expect(result.to_s).to start_with('Schema validation failed: ')
    end

    # There is nothing to constrain until the tables are there, so those checks are not run.
    it 'does not look for constraints on tables that do not exist' do
      validator.validate(connection)
      expect(sql_runner).not_to have_received(:query).with(connection, /table_constraints tc/, any_args)
    end
  end

  describe 'a schema with only one of the two tables' do
    let(:tables) { ['encryption_metadata'] }

    it 'reports the missing table' do
      expect(validator.validate(connection).issues).to eq(["Table 'encrypt.key_storage' does not exist"])
    end
  end

  describe 'a table that is missing a column' do
    it 'names every missing metadata column' do
      columns['encryption_metadata'] = %w[table_name column_name key_id]

      expect(validator.validate(connection).issues).to include(
        "Table 'encrypt.encryption_metadata' is missing required column 'encryption_algorithm'",
        "Table 'encrypt.encryption_metadata' is missing required column 'created_at'",
        "Table 'encrypt.encryption_metadata' is missing required column 'updated_at'"
      )
    end

    it 'names every missing key storage column' do
      columns['key_storage'] = %w[id key_id]

      expect(validator.validate(connection).issues).to include(
        "Table 'encrypt.key_storage' is missing required column 'hmac_key'",
        "Table 'encrypt.key_storage' is missing required column 'encrypted_data_key'"
      )
    end
  end

  describe 'a metadata table without the unique constraint' do
    # Without it the same column could be configured twice, with two different keys, and which
    # key a value was encrypted with would depend on which row was read.
    it 'reports the missing constraint' do
      constraints['encryption_metadata'] = { 'encryption_metadata_table_name_key' => ['table_name'] }

      expect(validator.validate(connection).issues)
        .to eq(["Table 'encrypt.encryption_metadata' is missing a unique constraint on (table_name, column_name)"])
    end

    it 'accepts a unique constraint that covers the two columns in either order' do
      constraints['encryption_metadata'] = { 'metadata_key' => %w[column_name table_name] }
      expect(validator.validate(connection)).to be_valid
    end

    it 'accepts a primary key over the two columns' do
      constraints['encryption_metadata'] = { 'encryption_metadata_pkey' => %w[table_name column_name] }
      expect(validator.validate(connection)).to be_valid
    end
  end

  describe 'a key storage table without a primary key' do
    it 'reports the missing primary key' do
      constraints['key_storage'] = {}

      expect(validator.validate(connection).issues)
        .to eq(["Table 'encrypt.key_storage' is missing a primary key on 'id'"])
    end

    it 'accepts a composite primary key that includes id' do
      constraints['key_storage'] = { 'key_storage_pkey' => %w[id key_id] }
      expect(validator.validate(connection)).to be_valid
    end
  end

  describe 'a metadata table that does not reference the key storage table' do
    it 'reports the missing foreign key' do
      foreign_keys['encryption_metadata'] = []

      expect(validator.validate(connection).issues)
        .to eq(['Missing foreign key constraint from encrypt.encryption_metadata.key_id to encrypt.key_storage.id'])
    end

    it 'reports a foreign key that points somewhere else' do
      foreign_keys['encryption_metadata'] = [{ from: 'key_id', to_table: 'other_keys', to_column: 'id' }]

      expect(validator.validate(connection).issues)
        .to eq(['Missing foreign key constraint from encrypt.encryption_metadata.key_id to encrypt.key_storage.id'])
    end

    it 'accepts the right foreign key among several' do
      foreign_keys['encryption_metadata'] = [{ from: 'tenant_id', to_table: 'tenants', to_column: 'id' },
                                             { from: 'key_id', to_table: 'key_storage', to_column: 'id' }]

      expect(validator.validate(connection)).to be_valid
    end

    # A missing column is the more useful thing to report first, and the foreign key check would
    # only add noise on a schema that is already known to be wrong.
    it 'is not checked while a column is still missing' do
      columns['key_storage'] = %w[id key_id]
      foreign_keys['encryption_metadata'] = []

      expect(validator.validate(connection).issues)
        .not_to include(/Missing foreign key constraint/)
    end
  end

  describe described_class::ValidationResult do
    it 'is valid when there are no issues' do
      expect(described_class.new).to be_valid
      expect(described_class.new.issues).to eq([])
    end

    it 'is invalid when there are issues, and lists them' do
      result = described_class.new(issues: %w[a b])

      expect(result).not_to be_valid
      expect(result.to_s).to eq('Schema validation failed: a, b')
      expect(result.inspect).to eq(result.to_s)
    end

    it 'can be told it is invalid even with no issues' do
      expect(described_class.new(valid: false)).not_to be_valid
    end
  end
end
