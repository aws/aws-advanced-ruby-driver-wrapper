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

require 'mysql2'
require 'securerandom'
require_relative 'integration_helper'
require_relative 'utils/test_environment'
require_relative 'utils/test_driver'
require_relative 'utils/database_engine'
require_relative 'utils/driver_helper'
require 'aws_ruby_database_driver_wrapper'
require 'aws_ruby_database_driver_wrapper/plugins/kms_encryption/encryption_service'

# Verifies the server-side MySQL trigger that is meant to reject plaintext writes to an encrypted
# column. It runs the SQL from
# spec/integration/host/src/test/resources/sql/encrypted_data_type_mysql.sql exactly as shipped,
# installs the example triggers on a users.ssn column, then checks two things:
#
#   1. A value in the plugin's real encrypted format (produced by EncryptionService, the same
#      serialization the plugin writes) is ACCEPTED. No KMS is needed: KMS only wraps the data key,
#      while the trigger verifies an HMAC computed from a key held in key_storage, so a random 32-byte
#      HMAC key is enough to build a payload the trigger must accept.
#   2. A plaintext value is REJECTED.
#
# How to read the result:
#   - Example 1 failing (a valid payload is rejected) means the trigger is broken for legitimate
#     data - either its hand-rolled hmac_sha256 does not match OpenSSL's HMAC, or its use of dynamic
#     SQL (PREPARE/EXECUTE) is not allowed in the trigger call path. In that case "it blocks
#     plaintext" is trivially true because it blocks everything.
#   - Example 1 passing and example 2 raising is the trigger working as intended.
#
# Prerequisites: a MySQL environment, and a DB user allowed to CREATE FUNCTION / PROCEDURE / TRIGGER.
# On Aurora/RDS MySQL that usually needs the cluster parameter log_bin_trust_function_creators = 1.
RSpec.describe 'KmsEncryption MySQL plaintext-blocking trigger', :integration,
               enable_on_engines: [Integration::DatabaseEngine::MYSQL] do
  # In MySQL a schema is a database; the metadata tables live in the connection's own database so the
  # test needs no CREATE DATABASE privilege. In production this would be a dedicated `encrypt` schema.
  let(:schema)   { info.default_dbname }
  let(:hmac_key) { SecureRandom.bytes(32) }
  let(:data_key) { SecureRandom.bytes(32) }
  let(:plaintext) { '123-45-6789' }

  let(:conn) do
    Integration::DriverHelper.native_connect(
      Integration::TestDriver::MYSQL,
      **Integration::DriverHelper.native_config(
        Integration::TestDriver::MYSQL,
        host: writer.host, port: writer.port, user: info.username,
        password: info.password, dbname: info.default_dbname
      )
    )
  end

  before do
    skip 'MySQL only' unless drv == Integration::TestDriver::MYSQL

    create_metadata_tables
    create_app_table
    store_key_and_metadata
    load_trigger_sql
    create_triggers
  end

  after do
    teardown
    conn.close
  rescue StandardError
    nil
  end

  it 'accepts a value written in the plugin encrypted format' do
    payload = AwsRubyDatabaseDriverWrapper::Plugins::Encryption::EncryptionService
              .encrypt(plaintext, data_key, hmac_key)

    expect { insert_binary(payload) }.not_to raise_error
    expect(user_count).to eq(1)
  end

  it 'rejects a plaintext write to the encrypted column' do
    expect { insert_plaintext(plaintext) }.to raise_error(Mysql2::Error)
    expect(user_count).to eq(0)
  end

  it 'rejects a random binary value that is not a valid payload' do
    expect { insert_binary(SecureRandom.bytes(80)) }.to raise_error(Mysql2::Error)
    expect(user_count).to eq(0)
  end

  # -- setup helpers --

  def create_metadata_tables
    conn.query("DROP TABLE IF EXISTS #{schema}.encryption_metadata")
    conn.query("DROP TABLE IF EXISTS #{schema}.key_storage")
    conn.query(<<~SQL)
      CREATE TABLE #{schema}.key_storage (
        id INT AUTO_INCREMENT PRIMARY KEY,
        name VARCHAR(255) NOT NULL,
        master_key_arn VARCHAR(512) NOT NULL,
        encrypted_data_key TEXT NOT NULL,
        hmac_key VARBINARY(32) NOT NULL,
        key_spec VARCHAR(50) DEFAULT 'AES_256'
      )
    SQL
    conn.query(<<~SQL)
      CREATE TABLE #{schema}.encryption_metadata (
        table_name VARCHAR(255) NOT NULL,
        column_name VARCHAR(255) NOT NULL,
        encryption_algorithm VARCHAR(50) NOT NULL,
        key_id INT NOT NULL,
        PRIMARY KEY (table_name, column_name),
        FOREIGN KEY (key_id) REFERENCES #{schema}.key_storage(id)
      )
    SQL
  end

  def create_app_table
    conn.query('DROP TABLE IF EXISTS users')
    conn.query(<<~SQL)
      CREATE TABLE users (
        id INT AUTO_INCREMENT PRIMARY KEY,
        name VARCHAR(100),
        ssn VARBINARY(512)
      )
    SQL
  end

  def store_key_and_metadata
    conn.query(<<~SQL)
      INSERT INTO #{schema}.key_storage (name, master_key_arn, encrypted_data_key, hmac_key, key_spec)
      VALUES ('users.ssn', 'arn:aws:kms:test:0:key/none', 'dGVzdA==', X'#{hex(hmac_key)}', 'AES_256')
    SQL
    key_id = conn.last_id
    conn.query(<<~SQL)
      INSERT INTO #{schema}.encryption_metadata (table_name, column_name, encryption_algorithm, key_id)
      VALUES ('users', 'ssn', 'AES-256-GCM', #{key_id})
    SQL
  end

  # Runs the shipped SQL file. The file is written for the mysql CLI (`DELIMITER $$`), which no driver
  # understands, so the DELIMITER directives are stripped and each statement (separated by `$$`) is
  # sent on its own - a compound BEGIN...END body needs no delimiter when sent as a single statement.
  def load_trigger_sql
    path = File.expand_path('../host/src/test/resources/sql/encrypted_data_type_mysql.sql', __dir__)
    sql = File.read(path).gsub('SCHEMA_NAME', schema)
    body = sql.lines.reject { |line| line.strip.start_with?('DELIMITER') }.join

    body.split('$$').each do |chunk|
      statement = chunk.strip
      next if statement.empty?
      next if statement.lines.all? { |line| line.strip.empty? || line.strip.start_with?('--') }

      conn.query(statement)
    end
  end

  def create_triggers
    conn.query('DROP TRIGGER IF EXISTS users_ssn_hmac_check')
    conn.query('DROP TRIGGER IF EXISTS users_ssn_hmac_check_update')
    conn.query(<<~SQL)
      CREATE TRIGGER users_ssn_hmac_check BEFORE INSERT ON users
      FOR EACH ROW BEGIN CALL validate_encrypted_data_hmac_before_insert('users', 'ssn', NEW.ssn); END
    SQL
    conn.query(<<~SQL)
      CREATE TRIGGER users_ssn_hmac_check_update BEFORE UPDATE ON users
      FOR EACH ROW BEGIN CALL validate_encrypted_data_hmac_before_insert('users', 'ssn', NEW.ssn); END
    SQL
  end

  def teardown
    conn.query('DROP TRIGGER IF EXISTS users_ssn_hmac_check')
    conn.query('DROP TRIGGER IF EXISTS users_ssn_hmac_check_update')
    conn.query('DROP TABLE IF EXISTS users')
    conn.query("DROP TABLE IF EXISTS #{schema}.encryption_metadata")
    conn.query("DROP TABLE IF EXISTS #{schema}.key_storage")
    conn.query('DROP PROCEDURE IF EXISTS validate_encrypted_data_hmac_before_insert')
    conn.query('DROP FUNCTION IF EXISTS verify_encrypted_data_hmac')
    conn.query('DROP FUNCTION IF EXISTS hmac_sha256')
  end

  # -- write helpers --

  def insert_binary(bytes)
    conn.query("INSERT INTO users (name, ssn) VALUES ('Jo', X'#{hex(bytes)}')")
  end

  def insert_plaintext(value)
    conn.query("INSERT INTO users (name, ssn) VALUES ('Jo', '#{conn.escape(value)}')")
  end

  def user_count
    conn.query('SELECT COUNT(*) AS c FROM users').first['c']
  end

  def hex(bytes)
    bytes.unpack1('H*')
  end
end
