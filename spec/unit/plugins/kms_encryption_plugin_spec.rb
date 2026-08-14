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

require_relative '../../spec_helper'
require 'aws_ruby_database_driver_wrapper/driver_dialects/pg_driver_dialect'
require 'aws_ruby_database_driver_wrapper/plugins/kms_encryption_plugin'
require 'aws_ruby_database_driver_wrapper/services/plugin_call_context'
require 'aws_ruby_database_driver_wrapper/services/service_container'

RSpec.describe AwsRubyDatabaseDriverWrapper::Plugins::KmsEncryptionPlugin do
  let(:encryption) { AwsRubyDatabaseDriverWrapper::Plugins::Encryption }
  let(:services) { AwsRubyDatabaseDriverWrapper::Services }
  let(:ruby_method) { AwsRubyDatabaseDriverWrapper::RubyMethod }
  let(:props) { Concurrent::Map.new }
  let(:driver_dialect) { AwsRubyDatabaseDriverWrapper::DriverDialects::PgDriverDialect.new }
  # A real runner and a real cipher over the pg dialect, so that what the plugin binds and what it
  # reads back go through the same binary handling as in production.
  let(:sql_runner) { encryption::SqlRunner.new(driver_dialect) }
  let(:data_key) { ('a' * 32).freeze }
  let(:key_manager) { instance_double(encryption::KeyManager) }
  let(:audit_logger) { encryption::AuditLogger.new(false) }
  let(:key_metadata) do
    encryption::KeyMetadata.new(id: 3, key_id: 'key-uuid', master_key_arn: 'arn:aws:kms:us-east-1:1:key/abcd',
                                encrypted_data_key: 'AQIDAHj...', hmac_key: 'h' * 32)
  end
  let(:ssn_config) { column_config('users', 'ssn') }
  let(:configs) { { 'users.ssn' => ssn_config, 'users.email' => column_config('users', 'email') } }
  let(:metadata_manager) { instance_double(encryption::MetadataManager) }
  let(:encryption_utility) do
    instance_double(encryption::KmsEncryptionUtility, ensure_initialized: nil, cleanup: nil,
                                                      metadata_manager: metadata_manager, key_manager: key_manager,
                                                      sql_runner: sql_runner, audit_logger: audit_logger)
  end
  let(:plugin_manager) { instance_double(services::PluginManager) }
  let(:service_container) do
    instance_double(services::ServiceContainer, plugin_manager: plugin_manager,
                                                dialect_service: instance_double(services::DialectService,
                                                                                 driver_dialect: driver_dialect))
  end
  subject(:plugin) { described_class.new(service_container, props, encryption_utility: encryption_utility) }

  before do
    # A fresh copy per call, since a cipher zeroes the key it was given when it is released.
    allow(key_manager).to receive(:decrypt_data_key) { +data_key }
    allow(metadata_manager).to receive(:column_config) { |table, column| configs["#{table}.#{column}"] }
    allow(metadata_manager).to receive(:table_configs) do |table|
      configs.select { |identifier, _| identifier.start_with?("#{table}.") }.values
    end
  end

  def column_config(table_name, column_name, metadata = key_metadata)
    encryption::ColumnEncryptionConfig.new(table_name: table_name, column_name: column_name, key_id: 3,
                                           key_metadata: metadata)
  end

  # Stands in for the pipeline: it publishes the call context the plugin reads the SQL, the
  # arguments and the block from, then calls the plugin with a callable standing in for the driver.
  def call(method_name, args: [], sql: nil, block: nil, returns: nil, &callable)
    @context = services::PluginCallContext.new(sql, args, block)
    allow(plugin_manager).to receive(:current_call_context).and_return(@context)
    plugin.execute(method_name, callable || -> { returns }, *args)
  end

  # What the driver method would be called with, after the plugin has had its say.
  def bound_args
    @context.args
  end

  # One encrypted column value, as the plugin would have written it.
  def ciphertext(value, config = ssn_config)
    cipher = encryption::ColumnCipher.new(key_manager: key_manager, sql_runner: sql_runner)
    begin
      cipher.encrypt(value, config)
    ensure
      cipher.release
    end
  end

  # What pg hands back for a bytea column.
  def bytea(bytes)
    "\\x#{bytes.unpack1('H*')}"
  end

  # Decrypts what the plugin bound, whichever driver it bound it for: pg takes a parameter and its
  # format, mysql2 takes the bytes.
  def plaintext(bound_value)
    raw = bound_value.is_a?(Hash) ? bytea(bound_value[:value]) : bound_value
    encryption::ColumnCipher.new(key_manager: key_manager, sql_runner: sql_runner).decrypt(raw, ssn_config)
  end

  describe '#initialize' do
    it 'subscribes to the statement, result and connection methods it has to intercept' do
      expect(plugin.subscribed_methods).to include('connection.exec_params', 'connection.exec', 'statement.execute',
                                                   'result.each', 'result.to_a', 'result.[]', 'result.field_values',
                                                   'connection.close')
    end

    it 'builds its own encryption utility from the properties' do
      allow(encryption::KmsEncryptionUtility).to receive(:new).and_return(encryption_utility)

      expect(described_class.new(service_container, props).encryption_utility).to be(encryption_utility)
      expect(encryption::KmsEncryptionUtility).to have_received(:new).with(service_container, props)
    end
  end

  describe '#key_management_utility' do
    it 'is the utility\'s administrative interface' do
      key_management_utility = instance_double(encryption::KeyManagementUtility)
      allow(encryption_utility).to receive(:key_management_utility).and_return(key_management_utility)

      expect(plugin.key_management_utility).to be(key_management_utility)
    end
  end

  describe 'closing the connection' do
    it 'releases what the plugin holds before the connection goes' do
      expect(call('connection.close', returns: :closed)).to eq(:closed)
      expect(encryption_utility).to have_received(:cleanup)
    end
  end

  describe 'encrypting bind parameters' do
    let(:insert) { 'INSERT INTO users (name, ssn) VALUES ($1, $2)' }

    it 'encrypts the parameter that belongs to an encrypted column and leaves the others alone' do
      call('connection.exec_params', args: [insert, %w[Jo 123-45-6789]], sql: insert)

      name, ssn = bound_args[1]
      expect(name).to eq('Jo')
      expect(ssn).to include(format: 1)
      expect(plaintext(ssn)).to eq('123-45-6789')
    end

    # The array belongs to the application, which is free to reuse it after the call.
    it 'leaves the parameter array the application passed as it was' do
      parameters = %w[Jo 123-45-6789]
      call('connection.exec_params', args: [insert, parameters], sql: insert)

      expect(parameters).to eq(%w[Jo 123-45-6789])
    end

    it 'encrypts the parameters of a prepared statement, which are the arguments themselves' do
      call('statement.execute', args: %w[Jo 123-45-6789], sql: insert)

      expect(bound_args.first).to eq('Jo')
      expect(plaintext(bound_args.last)).to eq('123-45-6789')
    end

    it 'encrypts what an UPDATE assigns to an encrypted column' do
      sql = 'UPDATE users SET ssn = $1 WHERE name = $2'
      call('connection.exec_params', args: [sql, %w[123-45-6789 Jo]], sql: sql)

      expect(plaintext(bound_args[1].first)).to eq('123-45-6789')
      expect(bound_args[1].last).to eq('Jo')
    end

    it 'leaves the arguments alone when no parameter belongs to an encrypted column' do
      sql = 'INSERT INTO users (name, nickname) VALUES ($1, $2)'
      args = [sql, %w[Jo Joey]]
      call('connection.exec_params', args: args, sql: sql)

      expect(bound_args).to be(args)
    end

    it 'leaves the arguments alone for a table that has no encrypted column' do
      sql = 'INSERT INTO audit_log (action, ssn) VALUES ($1, $2)'
      args = [sql, %w[login 123-45-6789]]
      call('connection.exec_params', args: args, sql: sql)

      expect(bound_args).to be(args)
    end

    # A nullable encrypted column still has to be able to hold null.
    it 'leaves a nil parameter null' do
      call('connection.exec_params', args: [insert, ['Jo', nil]], sql: insert)

      expect(bound_args[1]).to eq(['Jo', nil])
      expect(key_manager).not_to have_received(:decrypt_data_key)
    end

    it 'encrypts a value compared against an encrypted column' do
      sql = 'SELECT name FROM users WHERE ssn = $1'
      call('connection.exec_params', args: [sql, ['123-45-6789']], sql: sql)

      expect(plaintext(bound_args[1].first)).to eq('123-45-6789')
    end

    # The annotation is the way out when a statement is too involved for the parser, so it has to
    # win over whatever the parser made of the statement.
    it 'takes the column from an annotation over the one the parser inferred' do
      sql = 'INSERT INTO users (name, nickname) VALUES ($1, /*@encrypt:users.ssn*/ $2)'
      call('connection.exec_params', args: [sql, %w[Jo Joey]], sql: sql)

      expect(plaintext(bound_args[1].last)).to eq('Joey')
    end

    it 'encrypts an annotated parameter of a statement the parser makes nothing of' do
      sql = 'INSERT INTO users SELECT $1, /*@encrypt:users.ssn*/ $2'
      call('connection.exec_params', args: [sql, %w[Jo 123-45-6789]], sql: sql)

      expect(plaintext(bound_args[1].last)).to eq('123-45-6789')
    end

    it 'does nothing when the call carries no SQL to parse' do
      args = [%w[Jo 123-45-6789]]
      call('statement.execute', args: args, sql: nil)

      expect(bound_args).to be(args)
      expect(encryption_utility).not_to have_received(:ensure_initialized)
    end

    # There is nothing to substitute, so the arguments go through untouched. The statement is still
    # looked at, since one that stores a value the plugin cannot reach has to be refused.
    it 'binds nothing when the call has no parameters' do
      call('connection.exec', args: [insert], sql: insert)
      expect(bound_args).to eq([insert])

      call('connection.exec_params', args: [insert, []], sql: insert)
      expect(bound_args[1]).to eq([])
    end

    it 'does nothing when the statement cannot store anything and has no parameters' do
      select = 'SELECT name FROM users'
      call('connection.exec', args: [select], sql: select)

      expect(bound_args).to eq([select])
      expect(encryption_utility).not_to have_received(:ensure_initialized)
    end

    # Encrypting with half a configuration would write a value nothing could read back, and going
    # ahead without encrypting would store the plaintext. Neither is a safe fallback, so the
    # statement fails instead.
    it 'refuses to store a value in a column whose configuration has no key material' do
      configs['users.ssn'] = column_config('users', 'ssn', nil)

      expect { call('connection.exec_params', args: [insert, %w[Jo 123-45-6789]], sql: insert) }
        .to raise_error(AwsRubyDatabaseDriverWrapper::Errors::MetadataError, /users\.ssn is incomplete/)
    end

    it 'records a failed encryption in the audit trail and lets the failure through' do
      allow(key_manager).to receive(:decrypt_data_key)
        .and_raise(AwsRubyDatabaseDriverWrapper::Errors::KeyManagementError.kms_connection_failed('AccessDenied'))
      allow(audit_logger).to receive(:log_encryption)

      expect { call('connection.exec_params', args: [insert, %w[Jo 123-45-6789]], sql: insert) }
        .to raise_error(AwsRubyDatabaseDriverWrapper::Errors::KeyManagementError)
      expect(audit_logger).to have_received(:log_encryption)
        .with(hash_including(table_name: 'users', column_name: 'ssn', success: false))
    end
  end

  describe 'decrypting rows' do
    let(:select) { 'SELECT name, ssn FROM users WHERE name = $1' }
    let(:encrypted_row) { { 'name' => 'Jo', 'ssn' => bytea(ciphertext('123-45-6789')) } }

    it 'decrypts every row handed to the block of each' do
      rows = []
      call('result.each', sql: select, block: ->(row) { rows << row }) { @context.block.call(encrypted_row) }

      expect(rows).to eq([{ 'name' => 'Jo', 'ssn' => '123-45-6789' }])
    end

    it 'decrypts the rows to_a returns' do
      result = call('result.to_a', sql: select, returns: [encrypted_row, encrypted_row])

      expect(result.map { |row| row['ssn'] }).to eq(%w[123-45-6789 123-45-6789])
    end

    it 'decrypts a single row read by index' do
      expect(call('result.[]', args: [0], sql: select, returns: encrypted_row))
        .to eq({ 'name' => 'Jo', 'ssn' => '123-45-6789' })
    end

    # The row the application is holding is the driver's, and the plugin is only passing through it.
    it 'leaves the row the driver returned as it was' do
      row = encrypted_row
      call('result.to_a', sql: select, returns: [row])

      expect(row['ssn']).to start_with('\\x')
    end

    it 'leaves the rows alone when no column of the statement is encrypted' do
      sql = 'SELECT action FROM audit_log'
      rows = [{ 'action' => 'login' }]

      expect(call('result.to_a', sql: sql, returns: rows)).to be(rows)
    end

    # Without field names there is nothing to match against the encryption configuration.
    it 'leaves a row that is not a hash alone' do
      row = ['Jo', bytea(ciphertext('123-45-6789'))]
      expect(call('result.[]', args: [0], sql: select, returns: row)).to be(row)
    end

    # A column that was written before encryption was turned on still has to read back.
    it 'leaves a value that is not an encrypted payload untouched' do
      row = { 'name' => 'Jo', 'ssn' => '123-45-6789' }
      expect(call('result.to_a', sql: select, returns: [row])).to eq([row])
    end

    # One cipher serves the whole call, so a statement returning many rows costs a single Decrypt.
    it 'unwraps the data key once for the whole result' do
      rows = Array.new(5) { encrypted_row }
      unwraps = 0
      allow(key_manager).to receive(:decrypt_data_key) do
        unwraps += 1
        +data_key
      end

      call('result.to_a', sql: select, returns: rows)

      expect(unwraps).to eq(1)
    end

    it 'decrypts the values of a named column' do
      values = [bytea(ciphertext('123-45-6789')), bytea(ciphertext('987-65-4321'))]

      expect(call('result.field_values', args: ['ssn'], sql: select, returns: values))
        .to eq(%w[123-45-6789 987-65-4321])
    end

    it 'leaves the values of a column that is not encrypted alone' do
      values = %w[Jo Sam]
      expect(call('result.field_values', args: ['name'], sql: select, returns: values)).to be(values)
    end

    # Two of the statement's tables can encrypt a column of the same name, and the row does not say
    # which of them a value came from.
    it 'takes the configuration of the first table that encrypts the column' do
      configs['orders.ssn'] = column_config('orders', 'ssn')
      sql = 'SELECT u.ssn FROM users u JOIN orders o ON o.user_id = u.id WHERE u.name = $1'

      call('result.to_a', sql: sql, returns: [{ 'ssn' => bytea(ciphertext('123-45-6789')) }])

      expect(metadata_manager).to have_received(:table_configs).with('users')
    end

    # A value that carries a valid integrity tag but cannot be decrypted means the column is
    # pointing at the wrong key, which the application has to hear about.
    it 'records a failed decryption in the audit trail and lets the failure through' do
      row = { 'ssn' => bytea(ciphertext('123-45-6789')) }
      allow(audit_logger).to receive(:log_decryption)
      allow(key_manager).to receive(:decrypt_data_key) { +('b' * 32) }

      expect { call('result.to_a', sql: select, returns: [row]) }
        .to raise_error(AwsRubyDatabaseDriverWrapper::Errors::EncryptionError)
      expect(audit_logger).to have_received(:log_decryption)
        .with(hash_including(table_name: 'users', column_name: 'ssn', success: false))
    end
  end

  # mysql2 binds every parameter positionally, writes binary columns as plain binary strings, and
  # reads them back the same way, so both halves of the plugin have to be checked over it too.
  describe 'with the mysql2 driver' do
    let(:driver_dialect) { AwsRubyDatabaseDriverWrapper::DriverDialects::MysqlDriverDialect.new }

    it 'encrypts the parameters of a statement bound with question marks' do
      call('statement.execute', args: %w[Jo 123-45-6789], sql: 'INSERT INTO users (name, ssn) VALUES (?, ?)')

      expect(bound_args.first).to eq('Jo')
      expect(bound_args.last.encoding).to eq(Encoding::BINARY)
      expect(plaintext(bound_args.last)).to eq('123-45-6789')
    end

    it 'takes the column from an annotation on a question mark placeholder' do
      sql = 'INSERT INTO users (name, nickname) VALUES (?, /*@encrypt:users.ssn*/ ?)'
      call('statement.execute', args: %w[Jo Joey], sql: sql)

      expect(plaintext(bound_args.last)).to eq('Joey')
    end

    it 'decrypts the binary column values of a row' do
      row = { 'name' => 'Jo', 'ssn' => ciphertext('123-45-6789') }

      expect(call('result.to_a', sql: 'SELECT name, ssn FROM users', returns: [row]))
        .to eq([{ 'name' => 'Jo', 'ssn' => '123-45-6789' }])
    end
  end

  # A read has a safe fallback and a write does not, so the two behave differently here: a read
  # hands the column over as the database holds it, while a statement that would store a parameter
  # raises rather than store the plaintext in a column that is configured to be encrypted.
  describe 'when the encryption tables cannot be read' do
    let(:select) { 'SELECT name, ssn FROM users WHERE name = $1' }
    let(:insert) { 'INSERT INTO users (name, ssn) VALUES ($1, $2)' }
    let(:unreadable) do
      AwsRubyDatabaseDriverWrapper::Errors::MetadataError.lookup_failed('relation does not exist')
    end

    # The application's statement is not the place to report that the plugin's own tables are
    # unreadable, so every column is left as the database holds it.
    it 'leaves the columns alone when the plugin cannot be initialized' do
      allow(encryption_utility).to receive(:ensure_initialized)
        .and_raise(AwsRubyDatabaseDriverWrapper::Errors::MetadataError.load_failed('relation does not exist'))
      allow(plugin.send(:logger)).to receive(:warn)
      rows = [{ 'ssn' => bytea(ciphertext('123-45-6789')) }]

      expect(call('result.to_a', sql: select, returns: rows)).to be(rows)
      expect(plugin.send(:logger)).to have_received(:warn)
        .with(/The KMS encryption plugin is not ready, leaving columns as they are/)
    end

    it 'leaves the columns alone when the metadata manager was never built' do
      allow(encryption_utility).to receive(:metadata_manager).and_return(nil)
      allow(plugin.send(:logger)).to receive(:warn)
      rows = [{ 'ssn' => bytea(ciphertext('123-45-6789')) }]

      expect(call('result.to_a', sql: select, returns: rows)).to be(rows)
      expect(plugin.send(:logger)).to have_received(:warn).with(/could not be built/)
    end

    it 'leaves the column alone when its configuration cannot be looked up' do
      allow(metadata_manager).to receive(:table_configs).and_raise(unreadable)
      allow(plugin.send(:logger)).to receive(:warn)
      rows = [{ 'ssn' => bytea(ciphertext('123-45-6789')) }]

      expect(call('result.to_a', sql: select, returns: rows)).to be(rows)
      expect(plugin.send(:logger)).to have_received(:warn)
        .with(/Could not read the encryption configuration of users/)
    end

    it 'fails an INSERT whose column configuration cannot be looked up' do
      allow(metadata_manager).to receive(:column_config).and_raise(unreadable)

      expect { call('connection.exec_params', args: [insert, %w[Jo 123-45-6789]], sql: insert) }
        .to raise_error(AwsRubyDatabaseDriverWrapper::Errors::MetadataError, /relation does not exist/)
    end

    it 'fails an UPDATE whose column configuration cannot be looked up' do
      sql = 'UPDATE users SET ssn = $1 WHERE name = $2'
      allow(metadata_manager).to receive(:column_config).and_raise(unreadable)

      expect { call('connection.exec_params', args: [sql, %w[123-45-6789 Jo]], sql: sql) }
        .to raise_error(AwsRubyDatabaseDriverWrapper::Errors::MetadataError)
    end

    # The plugin cannot tell an INSERT into an encrypted column from any other INSERT without the
    # configuration, so it cannot let one through either.
    it 'fails an INSERT when the plugin cannot be initialized' do
      allow(encryption_utility).to receive(:ensure_initialized)
        .and_raise(AwsRubyDatabaseDriverWrapper::Errors::MetadataError.load_failed('relation does not exist'))

      expect { call('connection.exec_params', args: [insert, %w[Jo 123-45-6789]], sql: insert) }
        .to raise_error(AwsRubyDatabaseDriverWrapper::Errors::MetadataError, /relation does not exist/)
    end

    it 'fails an INSERT when the metadata manager was never built' do
      allow(encryption_utility).to receive(:metadata_manager).and_return(nil)

      expect { call('connection.exec_params', args: [insert, %w[Jo 123-45-6789]], sql: insert) }
        .to raise_error(AwsRubyDatabaseDriverWrapper::Errors::MetadataError, /could not be built/)
    end

    # A parameter of a SELECT is compared, not stored, so there is nothing to leak by letting it
    # through unencrypted: the comparison simply will not match.
    it 'lets a SELECT through when its parameter cannot be checked' do
      allow(metadata_manager).to receive(:column_config).and_raise(unreadable)
      allow(plugin.send(:logger)).to receive(:warn)
      sql = 'SELECT name FROM users WHERE ssn = $1'
      args = [sql, ['123-45-6789']]

      call('connection.exec_params', args: args, sql: sql)

      expect(bound_args).to be(args)
    end
  end

  # The plugin can only encrypt a value that arrives as a bind parameter, and only when it knows
  # which column that parameter fills. Anything else it can see writing an encrypted column has to
  # be refused, since a plaintext stored in one reads back as a plaintext ever after and nothing
  # would surface it.
  describe 'refusing a write it cannot encrypt' do
    let(:metadata_error) { AwsRubyDatabaseDriverWrapper::Errors::MetadataError }

    it 'refuses a literal written into an encrypted column' do
      sql = "INSERT INTO users (name, ssn) VALUES ($1, '123-45-6789')"

      expect { call('connection.exec_params', args: [sql, ['Jo']], sql: sql) }
        .to raise_error(metadata_error, /ssn is configured for encryption/)
    end

    it 'refuses an expression wrapped around a parameter of an encrypted column' do
      sql = 'UPDATE users SET ssn = upper($1) WHERE name = $2'

      expect { call('connection.exec_params', args: [sql, %w[123-45-6789 Jo]], sql: sql) }
        .to raise_error(metadata_error, /other than a bind parameter/)
    end

    it 'refuses a statement with no bind parameters at all' do
      sql = "INSERT INTO users (name, ssn) VALUES ('Jo', '123-45-6789')"

      expect { call('connection.query', args: [sql], sql: sql) }
        .to raise_error(metadata_error, /ssn is configured for encryption/)
    end

    it 'refuses an INSERT that does not name the columns it writes' do
      sql = 'INSERT INTO users VALUES ($1, $2)'

      expect { call('connection.exec_params', args: [sql, %w[Jo 123-45-6789]], sql: sql) }
        .to raise_error(metadata_error, /which of them this statement writes could not be established/)
    end

    it 'refuses an INSERT whose values come from a nested SELECT' do
      sql = 'INSERT INTO users (name, ssn) SELECT name, ssn FROM imported'

      expect { call('connection.exec', args: [sql], sql: sql) }
        .to raise_error(metadata_error, /could not be established/)
    end

    it 'refuses a write it could not parse' do
      sql = 'INSERT INTO ((( $1'
      allow(plugin.send(:logger)).to receive(:warn)

      expect { call('connection.exec_params', args: [sql, ['123-45-6789']], sql: sql) }
        .to raise_error(metadata_error, /neither the tables nor the columns it writes/)
    end

    it 'lets a write of a table with no encrypted column through' do
      sql = "INSERT INTO audit (event) VALUES ('login')"
      args = [sql]

      call('connection.query', args: args, sql: sql)

      expect(bound_args).to be(args)
    end

    it 'lets a literal written into a column that is not encrypted through' do
      sql = "INSERT INTO users (name, ssn) VALUES ('Jo', $1)"

      call('connection.exec_params', args: [sql, ['123-45-6789']], sql: sql)

      expect(plaintext(bound_args[1][0])).to eq('123-45-6789')
    end

    # An annotation names the column a parameter belongs to, which is exactly what the refusals are
    # missing, so a statement that carries one is taken at its word.
    it 'takes an annotated statement at its word' do
      sql = 'INSERT INTO users VALUES ($1, /*@encrypt:users.ssn*/ $2)'

      call('connection.exec_params', args: [sql, %w[Jo 123-45-6789]], sql: sql)

      expect(plaintext(bound_args[1][1])).to eq('123-45-6789')
    end

    it 'reads a statement it refuses to write from' do
      sql = 'SELECT name FROM users'
      rows = [{ 'ssn' => bytea(ciphertext('123-45-6789')) }]

      expect(call('result.to_a', sql: sql, returns: rows).first['ssn']).to eq('123-45-6789')
    end
  end

  # An encryption_metadata row whose key_storage row is gone comes back with no key material. The
  # column is still configured for encryption, so it cannot be written in the clear.
  describe 'when a column has no key material' do
    let(:configs) { { 'users.ssn' => column_config('users', 'ssn', nil) } }

    it 'refuses to write it' do
      sql = 'INSERT INTO users (name, ssn) VALUES ($1, $2)'

      expect { call('connection.exec_params', args: [sql, %w[Jo 123-45-6789]], sql: sql) }
        .to raise_error(AwsRubyDatabaseDriverWrapper::Errors::MetadataError, /configuration of users.ssn is incomplete/)
    end

    it 'leaves it alone on a read' do
      allow(plugin.send(:logger)).to receive(:warn)
      rows = [{ 'ssn' => 'whatever the database holds' }]

      expect(call('result.to_a', sql: 'SELECT ssn FROM users', returns: rows)).to be(rows)
      expect(plugin.send(:logger)).to have_received(:warn).with(/users.ssn: its encryption configuration is incomplete/)
    end
  end
end
