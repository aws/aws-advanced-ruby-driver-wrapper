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

require_relative 'integration_helper'
require_relative 'utils/test_environment'
require_relative 'utils/test_environment_features'
require_relative 'utils/test_driver'
require_relative 'utils/driver_helper'
require_relative 'utils/kms_encryption_helper'
require 'aws_advanced_ruby_driver_wrapper'

# The master key a column's data key is decrypted with is read from key_storage. These specs rewrite
# that row the way someone with write access to the metadata schema could, and check that the plugin
# refuses to use a master key outside encryption_allowed_master_key_arns rather than calling KMS with it.
RSpec.describe 'KmsEncryption master key allow-list', :integration, :kms_encryption,
               enable_on_engines: [Integration::DatabaseEngine::MYSQL, Integration::DatabaseEngine::PG],
               disable_on_features: [Integration::TestEnvironmentFeatures::PERFORMANCE] do
  include Integration::KmsEncryptionHelper

  let(:key_error) { AwsAdvancedRubyDriverWrapper::Errors::KeyManagementError }
  let(:allow_list_property) { AwsAdvancedRubyDriverWrapper::PropertyDefinition::ENCRYPTION_ALLOWED_MASTER_KEY_ARNS.name }
  let(:table) { 'enc_allow_list' }
  let(:admin_conn) { native_connect }
  let(:unlisted_arn) { "arn:aws:kms:#{kms_region}:000000000000:key/00000000-0000-0000-0000-000000000000" }

  before do
    require_kms!
    provision(admin_conn, table: table, encrypted_columns: ['ssn'], plain_columns: ['name'])
    @connections = []
  end

  after do
    @connections&.each { |conn| Integration::DriverHelper.close(drv, conn) }
    teardown_encryption(admin_conn, table: table)
    admin_conn && Integration::DriverHelper.close(drv, admin_conn)
  rescue StandardError
    nil
  end

  it 'refuses to start the plugin without an allow-list' do
    expect { open_connection(allow_list_property => nil) }
      .to raise_error(/encryption_allowed_master_key_arns is required/)
  end

  context 'when key_storage names a master key outside the allow-list' do
    before do
      insert(open_connection, 'Alice', '111-11-1111')
      repoint_master_key(unlisted_arn)
    end

    it 'refuses to decrypt the column' do
      conn = open_connection

      expect { read_ssn(conn, 'Alice') }
        .to raise_error(key_error) { |error| expect(error.code).to eq(key_error::UNAUTHORIZED_MASTER_KEY) }
    end

    it 'refuses to encrypt a new value into the column' do
      conn = open_connection

      expect { insert(conn, 'Bob', '222-22-2222') }
        .to raise_error(key_error) { |error| expect(error.code).to eq(key_error::UNAUTHORIZED_MASTER_KEY) }
      expect(count_rows(admin_conn, 'Bob')).to eq(0)
    end

    # Returning stored values unverified is only for data that fails its integrity check; a refused
    # master key is never let through.
    it 'refuses even when unverified data may be returned' do
      conn = open_connection(AwsAdvancedRubyDriverWrapper::PropertyDefinition::ENCRYPTION_RETURN_UNVERIFIED_DATA.name => true)

      expect { read_ssn(conn, 'Alice') }
        .to raise_error(key_error) { |error| expect(error.code).to eq(key_error::UNAUTHORIZED_MASTER_KEY) }
    end
  end

  # A fresh connection builds its own metadata and data key caches, so it reads key_storage as it
  # stands now.
  def open_connection(**extra_props)
    conn = encryption_connect(**extra_props)
    @connections << conn
    conn
  end

  def repoint_master_key(arn)
    case drv
    when Integration::TestDriver::PG
      admin_conn.exec_params("UPDATE #{schema_ref('key_storage')} SET master_key_arn = $1", [arn])
    when Integration::TestDriver::MYSQL
      admin_conn.query("UPDATE #{schema_ref('key_storage')} SET master_key_arn = '#{admin_conn.escape(arn)}'")
    end
  end

  def insert(conn, name, ssn)
    case drv
    when Integration::TestDriver::PG
      conn.exec_params("INSERT INTO #{table} (name, ssn) VALUES ($1, $2)", [name, ssn])
    when Integration::TestDriver::MYSQL
      conn.prepare("INSERT INTO #{table} (name, ssn) VALUES (?, ?)").execute(name, ssn)
    end
  end

  def read_ssn(conn, name)
    case drv
    when Integration::TestDriver::PG
      conn.exec_params("SELECT ssn FROM #{table} WHERE name = $1", [name]).first['ssn']
    when Integration::TestDriver::MYSQL
      conn.prepare("SELECT ssn FROM #{table} WHERE name = ?").execute(name).first['ssn']
    end
  end

  def count_rows(conn, name)
    case drv
    when Integration::TestDriver::PG
      conn.exec_params("SELECT COUNT(*) AS c FROM #{table} WHERE name = $1", [name]).first['c'].to_i
    when Integration::TestDriver::MYSQL
      conn.query("SELECT COUNT(*) AS c FROM #{table} WHERE name = '#{conn.escape(name)}'").first['c'].to_i
    end
  end
end
