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

require 'securerandom'
require_relative 'integration_helper'
require_relative 'utils/test_environment'
require_relative 'utils/test_environment_features'
require_relative 'utils/test_driver'
require_relative 'utils/driver_helper'
require_relative 'utils/kms_encryption_helper'
require 'aws_advanced_ruby_driver_wrapper'
require 'aws_advanced_ruby_driver_wrapper/plugins/kms_encryption/encryption_service'

# Server-side enforcement. The plugin cannot guarantee an encrypted column never holds a plaintext -
# only a database trigger can, by verifying each value's HMAC tag as it goes in (the HMAC key is
# stored in key_storage, so the server can check integrity without any data key). This exercises the
# shipped trigger SQL on both engines: a value in the plugin's real encrypted format is accepted, a
# plaintext is rejected, and a random binary value that is not a valid payload is rejected.
#
# The MySQL functions require the cluster parameter log_bin_trust_function_creators = 1 to be
# created on Aurora/RDS MySQL.
RSpec.describe 'KmsEncryption server-side triggers', :integration, :kms_encryption,
               enable_on_engines: [Integration::DatabaseEngine::MYSQL, Integration::DatabaseEngine::PG],
               disable_on_features: [Integration::TestEnvironmentFeatures::PERFORMANCE] do
  include Integration::KmsEncryptionHelper

  let(:encryption_service) { AwsAdvancedRubyDriverWrapper::Plugins::Encryption::EncryptionService }
  let(:table) { 'users' }
  let(:plaintext) { '123-45-6789' }
  let(:admin_conn) { native_connect }
  # Keys for the configured column, so a valid payload can be built by hand.
  let(:keys) { @keys }

  after do
    drop_triggers(admin_conn)
    teardown_encryption(admin_conn, table: table)
    admin_conn && Integration::DriverHelper.close(drv, admin_conn)
  rescue StandardError
    nil
  end

  context 'on PostgreSQL' do
    before do
      skip 'PostgreSQL only' unless drv == Integration::TestDriver::PG
      require_kms!

      run(admin_conn, 'CREATE EXTENSION IF NOT EXISTS pgcrypto')
      create_metadata_tables(admin_conn)
      install_pg_trigger_functions(admin_conn)
      create_app_table(admin_conn, table, encrypted_columns: ['ssn'], plain_columns: ['name'],
                                          pg_encrypted_type: 'encrypted_data')
      @keys = configure_column(admin_conn, table, 'ssn')
      create_pg_trigger(admin_conn)
    end

    it 'accepts a value written in the plugin encrypted format' do
      payload = encryption_service.encrypt(plaintext, keys[:data_key], keys[:hmac_key])
      expect { insert_binary(admin_conn, payload) }.not_to raise_error
      expect(user_count(admin_conn)).to eq(1)
    end

    it 'rejects a plaintext write to the encrypted column' do
      expect { insert_binary(admin_conn, 'plain-text-ssn') }.to raise_error(PG::Error)
      expect(user_count(admin_conn)).to eq(0)
    end

    it 'rejects a random binary value that is not a valid payload' do
      expect { insert_binary(admin_conn, SecureRandom.bytes(80)) }.to raise_error(PG::Error)
      expect(user_count(admin_conn)).to eq(0)
    end
  end

  context 'on MySQL' do
    before do
      skip 'MySQL only' unless drv == Integration::TestDriver::MYSQL
      require_kms!

      create_metadata_tables(admin_conn)
      create_app_table(admin_conn, table, encrypted_columns: ['ssn'], plain_columns: ['name'])
      @keys = configure_column(admin_conn, table, 'ssn')
      install_mysql_trigger_functions(admin_conn)
      create_mysql_triggers(admin_conn)
    end

    it 'accepts a value written in the plugin encrypted format' do
      payload = encryption_service.encrypt(plaintext, keys[:data_key], keys[:hmac_key])
      expect { insert_binary(admin_conn, payload) }.not_to raise_error
      expect(user_count(admin_conn)).to eq(1)
    end

    it 'rejects a plaintext write to the encrypted column' do
      expect { insert_binary(admin_conn, 'plain-text-ssn') }.to raise_error(Mysql2::Error)
      expect(user_count(admin_conn)).to eq(0)
    end

    it 'rejects a random binary value that is not a valid payload' do
      expect { insert_binary(admin_conn, SecureRandom.bytes(80)) }.to raise_error(Mysql2::Error)
      expect(user_count(admin_conn)).to eq(0)
    end
  end

  # -- trigger installation --

  def sql_resource(name)
    File.read(File.expand_path("host/src/test/resources/sql/#{name}", "#{__dir__}/.."))
        .gsub('SCHEMA_NAME', metadata_schema)
  end

  # PostgreSQL understands the file's dollar-quoted bodies and multiple statements in one call.
  def install_pg_trigger_functions(conn)
    conn.exec(sql_resource('encrypted_data_type.sql'))
  end

  def create_pg_trigger(conn)
    run(conn, 'DROP TRIGGER IF EXISTS users_ssn_hmac_check ON users')
    run(conn, <<~SQL)
      CREATE TRIGGER users_ssn_hmac_check BEFORE INSERT OR UPDATE ON users
      FOR EACH ROW EXECUTE FUNCTION validate_encrypted_data_hmac('ssn')
    SQL
  end

  # The MySQL file is written for the mysql CLI (DELIMITER $$), which no driver understands, so the
  # DELIMITER directives are stripped and each $$-separated statement is sent on its own.
  def install_mysql_trigger_functions(conn)
    body = sql_resource('encrypted_data_type_mysql.sql')
           .lines.reject { |line| line.strip.start_with?('DELIMITER') }.join

    body.split('$$').each do |chunk|
      statement = chunk.strip
      next if statement.empty?
      next if statement.lines.all? { |line| line.strip.empty? || line.strip.start_with?('--') }

      conn.query(statement)
    end
  end

  def create_mysql_triggers(conn)
    run(conn, 'DROP TRIGGER IF EXISTS users_ssn_hmac_check')
    run(conn, 'DROP TRIGGER IF EXISTS users_ssn_hmac_check_update')
    conn.query(<<~SQL)
      CREATE TRIGGER users_ssn_hmac_check BEFORE INSERT ON users
      FOR EACH ROW BEGIN CALL validate_encrypted_data_hmac_before_insert('users', 'ssn', NEW.ssn); END
    SQL
    conn.query(<<~SQL)
      CREATE TRIGGER users_ssn_hmac_check_update BEFORE UPDATE ON users
      FOR EACH ROW BEGIN CALL validate_encrypted_data_hmac_before_insert('users', 'ssn', NEW.ssn); END
    SQL
  end

  def drop_triggers(conn)
    case drv
    when Integration::TestDriver::PG
      run(conn, 'DROP TRIGGER IF EXISTS users_ssn_hmac_check ON users')
      run(conn, 'DROP FUNCTION IF EXISTS validate_encrypted_data_hmac() CASCADE')
      run(conn, 'DROP FUNCTION IF EXISTS verify_encrypted_data_hmac(encrypted_data, bytea) CASCADE')
      run(conn, 'DROP FUNCTION IF EXISTS has_valid_hmac_structure(encrypted_data) CASCADE')
      run(conn, 'DROP DOMAIN IF EXISTS encrypted_data CASCADE')
    when Integration::TestDriver::MYSQL
      run(conn, 'DROP TRIGGER IF EXISTS users_ssn_hmac_check')
      run(conn, 'DROP TRIGGER IF EXISTS users_ssn_hmac_check_update')
      run(conn, 'DROP PROCEDURE IF EXISTS validate_encrypted_data_hmac_before_insert')
      run(conn, 'DROP FUNCTION IF EXISTS verify_encrypted_data_hmac')
      run(conn, 'DROP FUNCTION IF EXISTS hmac_sha256')
    end
  end

  # -- writes --

  def insert_binary(conn, bytes)
    case drv
    when Integration::TestDriver::PG
      conn.exec_params("INSERT INTO #{table} (name, ssn) VALUES ($1, $2)",
                       ['Jo', { value: bytes.b, format: 1 }])
    when Integration::TestDriver::MYSQL
      conn.query("INSERT INTO #{table} (name, ssn) VALUES ('Jo', X'#{hex(bytes)}')")
    end
  end

  def user_count(conn)
    case drv
    when Integration::TestDriver::PG
      conn.exec("SELECT COUNT(*) AS c FROM #{table}").first['c'].to_i
    when Integration::TestDriver::MYSQL
      conn.query("SELECT COUNT(*) AS c FROM #{table}").first['c'].to_i
    end
  end
end
