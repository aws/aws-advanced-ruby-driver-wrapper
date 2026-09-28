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
require 'aws_advanced_ruby_driver_wrapper/driver_dialects/mysql_driver_dialect'
require 'aws_advanced_ruby_driver_wrapper/driver_dialects/pg_driver_dialect'
require 'aws_advanced_ruby_driver_wrapper/plugins/kms_encryption/kms_encryption_plugin'
require 'aws_advanced_ruby_driver_wrapper/services/plugin_call_context'
require 'aws_advanced_ruby_driver_wrapper/services/service_container'
require 'aws_advanced_ruby_driver_wrapper/utils/parser/pg_statement_analyzer'

RSpec.describe AwsAdvancedRubyDriverWrapper::Plugins::KmsEncryptionPlugin do
  let(:encryption) { AwsAdvancedRubyDriverWrapper::Plugins::Encryption }
  let(:services) { AwsAdvancedRubyDriverWrapper::Services }
  let(:ruby_method) { AwsAdvancedRubyDriverWrapper::RubyMethod }
  let(:props) { Concurrent::Map.new }
  let(:driver_dialect) { AwsAdvancedRubyDriverWrapper::DriverDialects::PgDriverDialect.new }
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
  let(:return_unverified_data) { false }
  let(:encryption_config) { instance_double(encryption::EncryptionConfig, return_unverified_data: return_unverified_data) }
  let(:encryption_utility) do
    instance_double(encryption::KmsEncryptionUtility, ensure_initialized: nil, cleanup: nil,
                                                      metadata_manager: metadata_manager, key_manager: key_manager,
                                                      sql_runner: sql_runner, audit_logger: audit_logger,
                                                      config: encryption_config)
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
  def call(method_name, args: [], sql: nil, block: nil, field_names: nil, returns: nil, &callable)
    @context = services::PluginCallContext.new(sql, args, block, field_names)
    allow(plugin_manager).to receive(:current_call_context).and_return(@context)
    plugin.execute(method_name, callable || -> { returns }, *args)
  end

  # What the driver method would be called with, after the plugin has had its say.
  def bound_args
    @context.args
  end

  # That a value was replaced by something that decrypts back to it: it is not the plaintext, and
  # decrypting it returns the plaintext.
  def expect_encrypted(bound_value, plaintext_value, message = nil)
    expect(bound_value).not_to eq(plaintext_value), message
    expect(plaintext(bound_value)).to eq(plaintext_value), message
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
                                                   'connection.query', 'connection.copy_data', 'result.each',
                                                   'result.each_row', 'result.to_a', 'result.[]', 'result.values',
                                                   'result.field_values', 'result.column_values', 'result.tuple',
                                                   'result.tuple_values', 'result.getvalue', 'result.stream_each',
                                                   'result.stream_each_row', 'result.stream_each_tuple',
                                                   'connection.close')
    end

    it 'builds its own kms_encryption utility from the properties' do
      allow(encryption::KmsEncryptionUtility).to receive(:new).and_return(encryption_utility)

      expect(described_class.new(service_container, props).encryption_utility).to be(encryption_utility)
      expect(encryption::KmsEncryptionUtility).to have_received(:new).with(service_container, props)
    end

    it 'fails as it is set up on PostgreSQL when pg_query is not installed' do
      allow(AwsAdvancedRubyDriverWrapper::Utils::Parser::PgStatementAnalyzer)
        .to receive(:require).with('pg_query').and_raise(LoadError)

      expect { plugin }.to raise_error(LoadError, /Add gem "pg_query" to your Gemfile/)
    end

    context 'with MySQL' do
      let(:driver_dialect) { AwsAdvancedRubyDriverWrapper::DriverDialects::MysqlDriverDialect.new }

      it 'does not need pg_query' do
        allow(AwsAdvancedRubyDriverWrapper::Utils::Parser::PgStatementAnalyzer).to receive(:require).and_raise(LoadError)

        expect { plugin }.not_to raise_error
      end
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
      expect_encrypted(ssn, '123-45-6789')
    end

    context 'when the SQL is binary' do
      let(:configs) { { 'users.größe' => ssn_config } }

      # SQL read from a file or socket is often binary. The pipeline publishes it as the UTF-8 the
      # server reads it as, so an encrypted column whose name is not ASCII is still found.
      it 'encrypts the parameter of an encrypted column' do
        binary = 'INSERT INTO users (name, größe) VALUES ($1, $2)'.b
        call('connection.exec_params', args: [binary, %w[Jo 123-45-6789]],
                                       sql: AwsAdvancedRubyDriverWrapper::Utils::SqlEncoding.inspectable(binary))

        expect_encrypted(bound_args[1][1], '123-45-6789')
      end
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
      expect_encrypted(bound_args.last, '123-45-6789')
    end

    it 'encrypts what an UPDATE assigns to an encrypted column' do
      sql = 'UPDATE users SET ssn = $1 WHERE name = $2'
      call('connection.exec_params', args: [sql, %w[123-45-6789 Jo]], sql: sql)

      expect_encrypted(bound_args[1].first, '123-45-6789')
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

      expect_encrypted(bound_args[1].first, '123-45-6789')
    end

    # The annotation is the way out when a statement is too involved for the parser, so it has to
    # win over whatever the parser made of the statement.
    it 'takes the column from an annotation over the one the parser inferred' do
      sql = 'INSERT INTO users (name, nickname) VALUES ($1, /*@encrypt:users.ssn*/ $2)'
      call('connection.exec_params', args: [sql, %w[Jo Joey]], sql: sql)

      expect_encrypted(bound_args[1].last, 'Joey')
    end

    it 'encrypts an annotated parameter of a statement the parser makes nothing of' do
      sql = 'INSERT INTO users SELECT $1, /*@encrypt:users.ssn*/ $2'
      call('connection.exec_params', args: [sql, %w[Jo 123-45-6789]], sql: sql)

      expect_encrypted(bound_args[1].last, '123-45-6789')
    end

    it 'does nothing when the call carries no SQL to parse and binds nothing' do
      args = []
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

    # A name read with a character its encoding had no UTF-8 form for cannot be matched against the
    # configuration, so it is left to the server-side enforcement rather than taken as not encrypted.
    context 'when a column name could not be read' do
      let(:unreadable) { "INSERT INTO users (name, gr\uFFFDe) VALUES ($1, $2)" }

      before { allow(plugin.send(:logger)).to receive(:warn) }

      it 'leaves the value to the database and says why' do
        call('connection.exec_params', args: [unreadable, %w[Jo 123-45-6789]], sql: unreadable)

        expect(bound_args[1]).to eq(%w[Jo 123-45-6789])
        expect(plugin.send(:logger)).to have_received(:warn).with(/cannot read the name users\.gr\uFFFDe/)
      end

      it 'warns once for a name, however many statements touch it' do
        3.times { call('connection.exec_params', args: [unreadable, %w[Jo 123-45-6789]], sql: unreadable) }

        expect(plugin.send(:logger)).to have_received(:warn).with(/cannot read the name users\.gr\uFFFDe/).once
      end

      it 'does not look the name up' do
        call('connection.exec_params', args: [unreadable, %w[Jo 123-45-6789]], sql: unreadable)

        expect(metadata_manager).not_to have_received(:column_config).with('users', "gr\uFFFDe")
      end
    end

    # A column configured for encryption but with no usable key material cannot be encrypted, so the
    # value is left for the database's enforcement to reject rather than the statement being refused.
    it 'passes a value through when its column configuration has no key material' do
      configs['users.ssn'] = column_config('users', 'ssn', nil)
      allow(plugin.send(:logger)).to receive(:warn)

      call('connection.exec_params', args: [insert, %w[Jo 123-45-6789]], sql: insert)

      expect(bound_args[1]).to eq(%w[Jo 123-45-6789])
    end

    it 'records a failed kms_encryption in the audit trail and lets the failure through' do
      allow(key_manager).to receive(:decrypt_data_key)
        .and_raise(AwsAdvancedRubyDriverWrapper::Errors::KeyManagementError.kms_connection_failed('AccessDenied'))
      allow(audit_logger).to receive(:log_encryption)

      expect { call('connection.exec_params', args: [insert, %w[Jo 123-45-6789]], sql: insert) }
        .to raise_error(AwsAdvancedRubyDriverWrapper::Errors::KeyManagementError)
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

    # each called without a block returns an Enumerator; the rows it yields must still be decrypted
    # rather than handed back as the stored ciphertext.
    it 'decrypts the rows of the enumerator each returns when called without a block' do
      enumerator = call('result.each', sql: select, returns: [encrypted_row, encrypted_row].each)

      expect(enumerator).to be_a(Enumerator)
      expect(enumerator.map { |row| row['ssn'] }).to eq(%w[123-45-6789 123-45-6789])
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

    # Without field names there is nothing to match against the kms_encryption configuration.
    it 'leaves a row that is not a hash alone' do
      row = ['Jo', bytea(ciphertext('123-45-6789'))]
      expect(call('result.[]', args: [0], sql: select, returns: row)).to be(row)
    end

    # The read fails closed: a value in an encrypted column that is not a valid payload (a value
    # written before kms_encryption was turned on) is refused rather than handed back.
    it 'raises on a value that is not an encrypted payload' do
      row = { 'name' => 'Jo', 'ssn' => '123-45-6789' }
      expect { call('result.to_a', sql: select, returns: [row]) }
        .to raise_error(AwsAdvancedRubyDriverWrapper::Errors::EncryptionError)
    end

    # The opt-in lenient read (encryption_return_unverified_data). Off by default and not for
    # production; it returns a value that cannot be confirmed to be encrypted data rather than raising.
    context 'when return_unverified_data is enabled' do
      let(:return_unverified_data) { true }

      before { allow(audit_logger).to receive(:log_decryption) }

      # A value that cannot be confirmed to be this column's encrypted data (here, a short value
      # written before kms_encryption was enabled) is returned as it is stored rather than raised on.
      it 'returns a value that cannot be verified as it is stored' do
        row = { 'name' => 'Jo', 'ssn' => '123-45-6789' }
        expect(call('result.to_a', sql: select, returns: [row])).to eq([row])
      end

      it 'records the unverified passthrough in the audit trail' do
        row = { 'name' => 'Jo', 'ssn' => '123-45-6789' }
        call('result.to_a', sql: select, returns: [row])
        expect(audit_logger).to have_received(:log_decryption)
          .with(hash_including(table_name: 'users', column_name: 'ssn', success: false))
      end

      # A value that verifies but will not decrypt (a wrong data key) is a real key fault, not
      # legacy data, so it still raises even in lenient mode.
      it 'still raises when a verified payload cannot be decrypted' do
        row = { 'ssn' => bytea(ciphertext('123-45-6789')) }
        allow(key_manager).to receive(:decrypt_data_key) { +('b' * 32) }

        expect { call('result.to_a', sql: select, returns: [row]) }
          .to raise_error(AwsAdvancedRubyDriverWrapper::Errors::EncryptionError, /authentication tag does not match this data key/)
      end
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

    # ActiveRecord reads rows as arrays of bare values rather than hashes, so those have to decrypt
    # too, matched to their columns by the field list the result reports.
    it 'decrypts the encrypted position of a row read as an array of values' do
      row = ['Jo', bytea(ciphertext('123-45-6789'))]
      expect(call('result.[]', args: [0], sql: select, field_names: %w[name ssn], returns: row))
        .to eq(%w[Jo 123-45-6789])
    end

    it 'decrypts the arrays to_a returns when the rows come back as arrays' do
      rows = [['Jo', bytea(ciphertext('123-45-6789'))], ['Sam', bytea(ciphertext('987-65-4321'))]]
      expect(call('result.to_a', sql: select, field_names: %w[name ssn], returns: rows))
        .to eq([%w[Jo 123-45-6789], %w[Sam 987-65-4321]])
    end

    # On a connection that is not UTF-8, a result names its columns in the connection's encoding while
    # the configuration names them in UTF-8.
    # Matching a result's names is done once per result, and a result on a UTF-8 connection names its
    # columns the way the configuration does, so it gets the columns without their being copied.
    describe 'matching the columns to the names a result uses' do
      let(:columns) { { 'ssn' => ssn_config } }

      it 'returns the columns as they are when the result names them the same way' do
        expect(plugin.send(:keyed_by_field_names, columns, %w[name ssn])).to equal(columns)
      end

      it 'adds a column the result names in another encoding, leaving the columns alone' do
        grosse = { 'größe' => ssn_config }
        keyed = plugin.send(:keyed_by_field_names, grosse, ['größe'.encode('ISO-8859-1')])

        expect(keyed).to include('größe'.encode('ISO-8859-1') => ssn_config, 'größe' => ssn_config)
        expect(grosse.keys).to eq(['größe'])
      end
    end

    context 'when the result names a column in another encoding' do
      let(:grosse_config) { column_config('users', 'größe') }
      let(:configs) { { 'users.größe' => grosse_config } }
      let(:select) { 'SELECT name, größe FROM users' }
      let(:latin1_name) { 'größe'.encode('ISO-8859-1') }
      let(:encrypted) { bytea(ciphertext('123-45-6789', grosse_config)) }

      it 'decrypts a row read as a hash' do
        row = { 'name' => 'Jo', latin1_name => encrypted }

        expect(call('result.[]', args: [0], sql: select, field_names: ['name', latin1_name], returns: row))
          .to eq({ 'name' => 'Jo', latin1_name => '123-45-6789' })
      end

      it 'decrypts a row read as an array of values' do
        row = ['Jo', encrypted]

        expect(call('result.[]', args: [0], sql: select, field_names: ['name', latin1_name], returns: row))
          .to eq(%w[Jo 123-45-6789])
      end

      it 'decrypts the values of the column read by name' do
        expect(call('result.field_values', args: [latin1_name], sql: select, returns: [encrypted]))
          .to eq(%w[123-45-6789])
      end
    end

    it 'decrypts the arrays values returns' do
      rows = [['Jo', bytea(ciphertext('123-45-6789'))], ['Sam', bytea(ciphertext('987-65-4321'))]]
      expect(call('result.values', sql: select, field_names: %w[name ssn], returns: rows))
        .to eq([%w[Jo 123-45-6789], %w[Sam 987-65-4321]])
    end

    it 'decrypts every array row handed to the block of each_row' do
      rows = []
      call('result.each_row', sql: select, field_names: %w[name ssn], block: ->(row) { rows << row }) do
        @context.block.call(['Jo', bytea(ciphertext('123-45-6789'))])
      end

      expect(rows).to eq([%w[Jo 123-45-6789]])
    end

    it 'decrypts the rows of the enumerator each_row returns when called without a block' do
      rows = [['Jo', bytea(ciphertext('123-45-6789'))]].each
      enumerator = call('result.each_row', sql: select, field_names: %w[name ssn], returns: rows)

      expect(enumerator.to_a).to eq([%w[Jo 123-45-6789]])
    end

    it 'decrypts the values of a column read by its position in the result' do
      values = [bytea(ciphertext('123-45-6789')), bytea(ciphertext('987-65-4321'))]
      expect(call('result.column_values', args: [1], sql: select, field_names: %w[name ssn], returns: values))
        .to eq(%w[123-45-6789 987-65-4321])
    end

    it 'leaves the values of a column read by position that is not encrypted alone' do
      values = %w[Jo Sam]
      expect(call('result.column_values', args: [0], sql: select, field_names: %w[name ssn], returns: values)).to be(values)
    end

    # Only the encrypted position is touched; the rest of the array is the driver's own.
    it 'leaves the other positions of an array row as they were' do
      row = ['Jo', bytea(ciphertext('123-45-6789'))]
      result = call('result.to_a', sql: select, field_names: %w[name ssn], returns: [row])

      expect(result.first.first).to eq('Jo')
      expect(row[1]).to start_with('\\x')
    end

    # getvalue reads a single cell by row and column position, matched to a column through the field
    # list - the pg analogue of a plain column read.
    it 'decrypts a single cell read by position when its column is encrypted' do
      value = bytea(ciphertext('123-45-6789'))
      expect(call('result.getvalue', args: [0, 1], sql: select, field_names: %w[name ssn], returns: value))
        .to eq('123-45-6789')
    end

    it 'leaves a single cell read by position alone when its column is not encrypted' do
      expect(call('result.getvalue', args: [0, 0], sql: select, field_names: %w[name ssn], returns: 'Jo')).to eq('Jo')
    end

    it 'decrypts the encrypted position of a single row read as an array by tuple_values' do
      row = ['Jo', bytea(ciphertext('123-45-6789'))]
      expect(call('result.tuple_values', args: [0], sql: select, field_names: %w[name ssn], returns: row))
        .to eq(%w[Jo 123-45-6789])
    end

    it 'decrypts every row handed to the block of stream_each' do
      rows = []
      call('result.stream_each', sql: select, field_names: %w[name ssn], block: ->(row) { rows << row }) do
        @context.block.call(encrypted_row)
      end

      expect(rows).to eq([{ 'name' => 'Jo', 'ssn' => '123-45-6789' }])
    end

    it 'decrypts every array row handed to the block of stream_each_row' do
      rows = []
      call('result.stream_each_row', sql: select, field_names: %w[name ssn], block: ->(row) { rows << row }) do
        @context.block.call(['Jo', bytea(ciphertext('123-45-6789'))])
      end

      expect(rows).to eq([%w[Jo 123-45-6789]])
    end

    it 'decrypts the rows handed to the block of stream_each_tuple' do
      rows = []
      call('result.stream_each_tuple', sql: select, field_names: %w[name ssn], block: ->(row) { rows << row }) do
        @context.block.call(encrypted_row)
      end

      expect(rows).to eq([{ 'name' => 'Jo', 'ssn' => '123-45-6789' }])
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
        .to raise_error(AwsAdvancedRubyDriverWrapper::Errors::EncryptionError)
      expect(audit_logger).to have_received(:log_decryption)
        .with(hash_including(table_name: 'users', column_name: 'ssn', success: false))
    end
  end

  # mysql2 binds every parameter positionally, writes binary columns as plain binary strings, and
  # reads them back the same way, so both halves of the plugin have to be checked over it too.
  describe 'with the mysql2 driver' do
    let(:driver_dialect) { AwsAdvancedRubyDriverWrapper::DriverDialects::MysqlDriverDialect.new }

    it 'encrypts the parameters of a statement bound with question marks' do
      call('statement.execute', args: %w[Jo 123-45-6789], sql: 'INSERT INTO users (name, ssn) VALUES (?, ?)')

      expect(bound_args.first).to eq('Jo')
      expect(bound_args.last.encoding).to eq(Encoding::BINARY)
      expect_encrypted(bound_args.last, '123-45-6789')
    end

    it 'takes the column from an annotation on a question mark placeholder' do
      sql = 'INSERT INTO users (name, nickname) VALUES (?, /*@encrypt:users.ssn*/ ?)'
      call('statement.execute', args: %w[Jo Joey], sql: sql)

      expect_encrypted(bound_args.last, 'Joey')
    end

    it 'decrypts the binary column values of a row' do
      row = { 'name' => 'Jo', 'ssn' => ciphertext('123-45-6789') }

      expect(call('result.to_a', sql: 'SELECT name, ssn FROM users', returns: [row]))
        .to eq([{ 'name' => 'Jo', 'ssn' => '123-45-6789' }])
    end

    # Query instrumentation prepends a comment to every statement it sees, so a write arriving behind
    # one is ordinary rather than exotic, and it has to be encrypted like any other.
    it 'encrypts the parameters of a write behind a comment' do
      call('statement.execute', args: %w[Jo 123-45-6789],
                                sql: '/* app:checkout */ INSERT INTO users (name, ssn) VALUES (?, ?)')

      expect(bound_args.first).to eq('Jo')
      expect_encrypted(bound_args.last, '123-45-6789')
    end

    it 'encrypts the parameters of a write behind a common table expression' do
      call('statement.execute', args: %w[Jo 123-45-6789],
                                sql: 'WITH t AS (SELECT 1) INSERT INTO users (name, ssn) VALUES (?, ?)')

      expect_encrypted(bound_args.last, '123-45-6789')
    end

    it 'passes a write it could not read through, leaving it to the database' do
      sql = 'WITH t AS (SELECT ((( INSERT INTO users (name, ssn) VALUES (?, ?)'
      args = %w[Jo 123-45-6789]

      call('statement.execute', args: args, sql: sql)

      expect(bound_args).to be(args)
    end

    # MySQL lets the target of an assignment carry the table it belongs to, or an alias for it, and
    # an application that aliases its tables writes every assignment that way.
    it 'encrypts a parameter assigned to a column named with its table' do
      call('statement.execute', args: ['123-45-6789', 7], sql: 'UPDATE users SET users.ssn = ? WHERE id = ?')

      expect_encrypted(bound_args.first, '123-45-6789')
    end

    it 'encrypts a parameter assigned to a column named with an alias for its table' do
      ['UPDATE users u SET u.ssn = ? WHERE u.id = ?',
       'UPDATE users AS u SET `u`.`ssn` = ? WHERE u.id = ?',
       'UPDATE mydb.users u SET u.ssn = ? WHERE u.id = ?'].each do |sql|
        call('statement.execute', args: ['123-45-6789', 7], sql: sql)

        expect_encrypted(bound_args.first, '123-45-6789', "for #{sql}")
      end
    end

    # The modifiers MySQL accepts in front of the table say how the statement behaves and nothing
    # about what it writes, so a write behind one is an ordinary write.
    it 'encrypts a parameter of a write sent behind a statement modifier' do
      ['UPDATE LOW_PRIORITY users SET ssn = ? WHERE id = ?',
       'UPDATE IGNORE users SET ssn = ? WHERE id = ?'].each do |sql|
        call('statement.execute', args: ['123-45-6789', 7], sql: sql)

        expect_encrypted(bound_args.first, '123-45-6789', "for #{sql}")
      end
    end

    it 'encrypts the parameters of an INSERT sent behind a statement modifier' do
      ['INSERT LOW_PRIORITY INTO users (name, ssn) VALUES (?, ?)',
       'INSERT DELAYED IGNORE INTO users (name, ssn) VALUES (?, ?)',
       'REPLACE LOW_PRIORITY INTO users (name, ssn) VALUES (?, ?)'].each do |sql|
        call('statement.execute', args: %w[Jo 123-45-6789], sql: sql)

        expect(bound_args.first).to eq('Jo'), "for #{sql}"
        expect_encrypted(bound_args.last, '123-45-6789', "for #{sql}")
      end
    end

    # MySQL lets an UPDATE write more than one table, and which of them +SET a.ssn = ?+ writes depends
    # on the aliases the reference list handed out. The plugin does not confidently map such an
    # assignment to a column, so it neither encrypts it (guessing the table could encrypt for the
    # wrong column) nor refuses the statement; it warns and leaves it to the database.
    describe 'an UPDATE of more than one table' do
      it 'is let through with a warning when any table it names has an encrypted column' do
        sql = 'UPDATE users u JOIN accounts a ON a.uid = u.id SET a.ssn = ? WHERE u.id = ?'
        args = ['123-45-6789', 7]
        allow(plugin.send(:logger)).to receive(:warn)

        call('statement.execute', args: args, sql: sql)

        expect(bound_args).to be(args)
        expect(plugin.send(:logger)).to have_received(:warn).with(/which of them this statement writes could not be established/)
      end

      it 'is let through when none of the tables it names has one' do
        sql = 'UPDATE audit_log l JOIN sessions s ON s.id = l.session_id SET s.token = ?'
        args = ['abcd']

        call('statement.execute', args: args, sql: sql)

        expect(bound_args).to be(args)
      end

      # The caller knows which table an assignment lands on even where the parser does not, and saying
      # so is what the annotation is for.
      it 'encrypts an annotated parameter of one' do
        sql = 'UPDATE users u JOIN accounts a ON a.uid = u.id SET u.ssn = /*@encrypt:users.ssn*/ ?'

        call('statement.execute', args: ['123-45-6789'], sql: sql)

        expect_encrypted(bound_args.first, '123-45-6789')
      end
    end
  end

  # When the plugin cannot read its own tables it cannot encrypt anything, so it leaves every column
  # as the database holds it - reads and writes alike - and relies on the required server-side
  # enforcement to reject a plaintext, rather than taking the application's statement down.
  describe 'when the kms_encryption tables cannot be read' do
    let(:select) { 'SELECT name, ssn FROM users WHERE name = $1' }
    let(:insert) { 'INSERT INTO users (name, ssn) VALUES ($1, $2)' }
    let(:unreadable) do
      AwsAdvancedRubyDriverWrapper::Errors::MetadataError.lookup_failed('relation does not exist')
    end

    # The application's statement is not the place to report that the plugin's own tables are
    # unreadable, so every column is left as the database holds it.
    it 'leaves the columns alone when the plugin cannot be initialized' do
      allow(encryption_utility).to receive(:ensure_initialized)
        .and_raise(AwsAdvancedRubyDriverWrapper::Errors::MetadataError.load_failed('relation does not exist'))
      allow(plugin.send(:logger)).to receive(:warn)
      rows = [{ 'ssn' => bytea(ciphertext('123-45-6789')) }]

      expect(call('result.to_a', sql: select, returns: rows)).to be(rows)
      expect(plugin.send(:logger)).to have_received(:warn)
        .with(/The kms_encryption plugin is not ready, leaving columns as they are/)
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
        .with(/Could not read the kms_encryption configuration of users/)
    end

    it 'passes an INSERT through when its column configuration cannot be looked up' do
      allow(metadata_manager).to receive(:column_config).and_raise(unreadable)
      allow(plugin.send(:logger)).to receive(:warn)

      call('connection.exec_params', args: [insert, %w[Jo 123-45-6789]], sql: insert)

      expect(bound_args[1]).to eq(%w[Jo 123-45-6789])
    end

    it 'passes an UPDATE through when its column configuration cannot be looked up' do
      sql = 'UPDATE users SET ssn = $1 WHERE name = $2'
      allow(metadata_manager).to receive(:column_config).and_raise(unreadable)
      allow(plugin.send(:logger)).to receive(:warn)

      call('connection.exec_params', args: [sql, %w[123-45-6789 Jo]], sql: sql)

      expect(bound_args[1]).to eq(%w[123-45-6789 Jo])
    end

    # Without the configuration the plugin cannot tell an INSERT into an encrypted column from any
    # other INSERT, so it leaves it to the database rather than refusing it.
    it 'passes an INSERT through when the plugin cannot be initialized' do
      allow(encryption_utility).to receive(:ensure_initialized)
        .and_raise(AwsAdvancedRubyDriverWrapper::Errors::MetadataError.load_failed('relation does not exist'))
      allow(plugin.send(:logger)).to receive(:warn)

      call('connection.exec_params', args: [insert, %w[Jo 123-45-6789]], sql: insert)

      expect(bound_args[1]).to eq(%w[Jo 123-45-6789])
    end

    it 'passes an INSERT through when the metadata manager was never built' do
      allow(encryption_utility).to receive(:metadata_manager).and_return(nil)
      allow(plugin.send(:logger)).to receive(:warn)

      call('connection.exec_params', args: [insert, %w[Jo 123-45-6789]], sql: insert)

      expect(bound_args[1]).to eq(%w[Jo 123-45-6789])
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

  # The plugin can only encrypt a value that arrives as a bind parameter it can map to a column. A
  # value it can see writing a confirmed encrypted column another way - a literal, an expression, a
  # DEFAULT - it refuses, since that is almost always a mistake. A write it cannot read that far it
  # leaves to the database rather than refusing, so as not to reject statements that touch no
  # encrypted column.
  describe 'a write it cannot encrypt' do
    let(:metadata_error) { AwsAdvancedRubyDriverWrapper::Errors::MetadataError }

    it 'refuses a literal written into an encrypted column' do
      sql = "INSERT INTO users (name, ssn) VALUES ($1, '123-45-6789')"

      expect { call('connection.exec_params', args: [sql, ['Jo']], sql: sql) }
        .to raise_error(metadata_error, /ssn is configured for kms_encryption/)
    end

    it 'refuses an expression wrapped around a parameter of an encrypted column' do
      sql = 'UPDATE users SET ssn = upper($1) WHERE name = $2'

      expect { call('connection.exec_params', args: [sql, %w[123-45-6789 Jo]], sql: sql) }
        .to raise_error(metadata_error, /other than a bind parameter/)
    end

    it 'refuses a statement with no bind parameters at all' do
      sql = "INSERT INTO users (name, ssn) VALUES ('Jo', '123-45-6789')"

      expect { call('connection.query', args: [sql], sql: sql) }
        .to raise_error(metadata_error, /ssn is configured for kms_encryption/)
    end

    it 'passes an INSERT that does not name its columns through, with a warning' do
      sql = 'INSERT INTO users VALUES ($1, $2)'
      allow(plugin.send(:logger)).to receive(:warn)

      call('connection.exec_params', args: [sql, %w[Jo 123-45-6789]], sql: sql)

      expect(bound_args[1]).to eq(%w[Jo 123-45-6789])
      expect(plugin.send(:logger)).to have_received(:warn).with(/which of them this statement writes could not be established/)
    end

    it 'passes an INSERT whose values come from a nested SELECT through, with a warning' do
      sql = 'INSERT INTO users (name, ssn) SELECT name, ssn FROM imported'
      args = [sql]
      allow(plugin.send(:logger)).to receive(:warn)

      call('connection.exec', args: args, sql: sql)

      expect(bound_args).to be(args)
      expect(plugin.send(:logger)).to have_received(:warn).with(/which of them this statement writes could not be established/)
    end

    it 'passes a write it could not parse through, leaving it to the database' do
      sql = 'INSERT INTO ((( $1'
      allow(plugin.send(:logger)).to receive(:warn)

      call('connection.exec_params', args: [sql, ['123-45-6789']], sql: sql)

      expect(bound_args[1]).to eq(['123-45-6789'])
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

      expect_encrypted(bound_args[1][0], '123-45-6789')
    end

    # An annotation names the column a parameter belongs to, which is exactly what the refusals are
    # missing, so a statement that carries one is taken at its word.
    it 'takes an annotated statement at its word' do
      sql = 'INSERT INTO users VALUES ($1, /*@encrypt:users.ssn*/ $2)'

      call('connection.exec_params', args: [sql, %w[Jo 123-45-6789]], sql: sql)

      expect_encrypted(bound_args[1][1], '123-45-6789')
    end

    # An annotation speaks for the column it names and no further. A statement that annotates one
    # parameter has said nothing about the second encrypted column it fills with a literal, and that
    # column would be stored in the clear, so it is still refused.
    it 'still refuses an encrypted column the annotation says nothing about' do
      sql = "INSERT INTO users (name, email, ssn) VALUES ($1, /*@encrypt:users.email*/ $2, '123-45-6789')"

      expect { call('connection.exec_params', args: [sql, %w[Jo jo@example.com]], sql: sql) }
        .to raise_error(metadata_error, /ssn is configured for kms_encryption/)
    end

    # A cast is not a bind parameter as far as the parser is concerned, but casting the ciphertext is
    # a reasonable thing to write, and the annotation says the parameter is the column's value.
    it 'excuses the column its annotation does name' do
      sql = 'INSERT INTO users (name, ssn) VALUES ($1, /*@encrypt:users.ssn*/ $2::bytea)'

      call('connection.exec_params', args: [sql, %w[Jo 123-45-6789]], sql: sql)

      expect_encrypted(bound_args[1][1], '123-45-6789')
    end

    # An annotation that names no table cannot be resolved against a statement whose tables are
    # unknown, so the value is left to the database like any other unparseable write.
    it 'passes a write it could not parse through even when it carries an annotation' do
      sql = 'INSERT INTO ((( /*@encrypt:ssn*/ $1'
      allow(plugin.send(:logger)).to receive(:warn)

      call('connection.exec_params', args: [sql, ['123-45-6789']], sql: sql)

      expect(bound_args[1]).to eq(['123-45-6789'])
    end

    # An application that aliases its tables annotates with the alias, since that is what the rest of
    # the statement says. Looking only for a table of that name would find nothing configured and
    # leave the value unencrypted.
    it 'resolves an annotation that names the table by its alias' do
      sql = 'INSERT INTO users AS u SELECT $1, /*@encrypt:u.ssn*/ $2'

      call('connection.exec_params', args: [sql, %w[Jo 123-45-6789]], sql: sql)

      expect_encrypted(bound_args[1][1], '123-45-6789')
    end

    it 'reads a statement it refuses to write from' do
      sql = 'SELECT name FROM users'
      rows = [{ 'ssn' => bytea(ciphertext('123-45-6789')) }]

      expect(call('result.to_a', sql: sql, returns: rows).first['ssn']).to eq('123-45-6789')
    end
  end

  # A prepared statement is run by name, and the connection publishes the statement it was prepared
  # with. A name it has no statement for is one prepared somewhere it could not read: the plugin
  # cannot tell which column a value belongs to, so it leaves the values to the database rather than
  # refusing the call.
  describe 'binding values to a statement it never saw' do
    it 'passes a prepared statement it has no statement for through' do
      call('connection.exec_prepared', args: ['prepared_elsewhere', ['123-45-6789']])

      expect(bound_args).to eq(['prepared_elsewhere', ['123-45-6789']])
    end

    it 'passes one sent asynchronously through as well' do
      call('connection.send_query_prepared', args: ['prepared_elsewhere', ['123-45-6789']])

      expect(bound_args).to eq(['prepared_elsewhere', ['123-45-6789']])
    end

    it 'passes a mysql2 prepared statement it has no statement for through' do
      call('statement.execute', args: ['123-45-6789'])

      expect(bound_args).to eq(['123-45-6789'])
    end

    it 'lets one that binds nothing through' do
      expect { call('connection.exec_prepared', args: ['prepared_elsewhere', []]) }.not_to raise_error
    end
  end

  # A PREPARE binds nothing itself, so the values in the statement it carries are the only values it
  # has, and the PREPARE is the only time its text is in hand: by the time an EXECUTE runs it, the
  # statement is the server's and a value written into it has already gone across in the clear.
  describe 'a statement sent to be prepared' do
    let(:metadata_error) { AwsAdvancedRubyDriverWrapper::Errors::MetadataError }

    it 'refuses a value written into the statement it carries' do
      sql = "PREPARE ins AS INSERT INTO users (ssn) VALUES ('123-45-6789')"

      expect { call('connection.exec', args: [sql], sql: sql) }
        .to raise_error(metadata_error, /ssn is configured for kms_encryption/)
    end

    it 'refuses one sent as a query as well' do
      sql = "PREPARE upd AS UPDATE users SET ssn = '123-45-6789' WHERE id = $1"

      expect { call('connection.query', args: [sql], sql: sql) }
        .to raise_error(metadata_error, /ssn is configured for kms_encryption/)
    end

    it 'lets one whose values are all parameters through' do
      sql = 'PREPARE ins (text, text) AS INSERT INTO users (name, ssn) VALUES ($1, $2)'
      args = [sql]

      call('connection.exec', args: args, sql: sql)

      expect(bound_args).to be(args)
    end

    # Nothing is bound by the PREPARE, so the parameters arrive with the exec_prepared that runs it,
    # against the statement the connection published for that name.
    it 'encrypts the parameters bound to it when it is run' do
      sql = 'INSERT INTO users (name, ssn) VALUES ($1, $2)'
      call('connection.exec_prepared', args: ['ins', %w[Jo 123-45-6789]], sql: sql)

      expect(bound_args[1].first).to eq('Jo')
      expect_encrypted(bound_args[1].last, '123-45-6789')
    end

    it 'lets a PREPARE of a table with no encrypted column through' do
      sql = "PREPARE log AS INSERT INTO audit (event) VALUES ('login')"
      args = [sql]

      call('connection.exec', args: args, sql: sql)

      expect(bound_args).to be(args)
    end
  end

  # A COPY feeds its rows to the server as a stream, so there is no bind parameter to replace and no
  # way to encrypt any column it writes. A COPY that names a confirmed encrypted column is refused
  # when it opens (there is no COPY to feed by then, which is why the calls that feed it are left
  # alone); one that names no columns is left to the database with a warning, like any write whose
  # columns cannot be enumerated.
  describe 'a COPY that would store a plaintext' do
    let(:metadata_error) { AwsAdvancedRubyDriverWrapper::Errors::MetadataError }

    it 'refuses a COPY that names an encrypted column' do
      sql = 'COPY users (name, ssn) FROM STDIN'

      expect { call('connection.copy_data', args: [sql], sql: sql) }
        .to raise_error(metadata_error, /ssn is configured for kms_encryption.*as a stream/m)
    end

    # Without a column list the stream fills the table's columns in the order the table declares
    # them, so an encrypted one could be among them - but which cannot be enumerated, so it is left
    # to the database.
    it 'passes a COPY that names none of a table with encrypted columns through, with a warning' do
      sql = 'COPY users FROM STDIN'
      allow(plugin.send(:logger)).to receive(:warn)

      expect(call('connection.copy_data', args: [sql], sql: sql, returns: :copied)).to be(:copied)
      expect(plugin.send(:logger)).to have_received(:warn).with(/which of them this statement writes could not be established/)
    end

    # The convenience form opens its COPY on the driver's own connection, so the statement is only
    # ever seen as an argument of the call itself. Sent on its own it arrives as any statement does.
    it 'refuses a COPY sent as a statement of its own' do
      sql = "COPY users (ssn) FROM '/tmp/users.csv'"

      expect { call('connection.exec', args: [sql], sql: sql) }
        .to raise_error(metadata_error, /ssn is configured for kms_encryption/)
    end

    # An annotation names the column a parameter belongs to, and a COPY has no parameters, so unlike
    # every other write it cannot be waved through with one.
    it 'refuses a COPY that carries an annotation' do
      sql = 'COPY users (name, ssn) FROM STDIN /*@encrypt:users.ssn*/'

      expect { call('connection.copy_data', args: [sql], sql: sql) }
        .to raise_error(metadata_error, /ssn is configured for kms_encryption/)
    end

    it 'lets a COPY into a table with no encrypted column through' do
      sql = 'COPY audit (event, at) FROM STDIN'
      args = [sql]

      expect(call('connection.copy_data', args: args, sql: sql, returns: :copied)).to be(:copied)
      expect(bound_args).to be(args)
    end

    it 'lets a COPY that names only columns which are not encrypted through' do
      sql = 'COPY users (name) FROM STDIN'

      expect(call('connection.copy_data', args: [sql], sql: sql, returns: :copied)).to be(:copied)
    end

    # A COPY that reads stores nothing, so it is left alone. What it hands out is whatever the column
    # holds, which for an encrypted column is the ciphertext.
    it 'lets a COPY that reads through' do
      sql = 'COPY users (name, ssn) TO STDOUT'

      expect(call('connection.copy_data', args: [sql], sql: sql, returns: :copied)).to be(:copied)
    end
  end

  # An encryption_metadata row whose key_storage row is gone comes back with no key material. The
  # plugin cannot encrypt the column, so it leaves the value to the database rather than the column
  # being treated as encrypted at all.
  describe 'when a column has no key material' do
    let(:configs) { { 'users.ssn' => column_config('users', 'ssn', nil) } }

    it 'passes a write of it through, leaving it to the database' do
      sql = 'INSERT INTO users (name, ssn) VALUES ($1, $2)'
      allow(plugin.send(:logger)).to receive(:warn)

      call('connection.exec_params', args: [sql, %w[Jo 123-45-6789]], sql: sql)

      expect(bound_args[1]).to eq(%w[Jo 123-45-6789])
      expect(plugin.send(:logger)).to have_received(:warn).with(/users.ssn: its kms_encryption configuration is incomplete/)
    end

    it 'leaves it alone on a read' do
      allow(plugin.send(:logger)).to receive(:warn)
      rows = [{ 'ssn' => 'whatever the database holds' }]

      expect(call('result.to_a', sql: 'SELECT ssn FROM users', returns: rows)).to be(rows)
      expect(plugin.send(:logger)).to have_received(:warn).with(/users.ssn: its kms_encryption configuration is incomplete/)
    end
  end
end
