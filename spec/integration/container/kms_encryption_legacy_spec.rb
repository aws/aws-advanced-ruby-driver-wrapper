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

# Legacy and mixed data. By default the read path fails closed: a value that does not carry a valid
# integrity tag - legacy data written before the column was encrypted, or a tampered value - is
# refused with an EncryptionError rather than handed back. The opt-in encryption_return_unverified_data
# property restores the lenient behavior, returning such a value exactly as the database holds it,
# which is proven by comparing a plugin read to a plain read of the same stored bytes.
RSpec.describe 'KmsEncryption legacy and mixed data', :integration, :kms_encryption,
               enable_on_engines: [Integration::DatabaseEngine::MYSQL, Integration::DatabaseEngine::PG],
               disable_on_features: [Integration::TestEnvironmentFeatures::PERFORMANCE] do
  include Integration::KmsEncryptionHelper

  let(:table) { 'enc_legacy' }
  let(:admin_conn) { native_connect }
  let(:conn) { encryption_connect }
  let(:encryption_error) { AwsAdvancedRubyDriverWrapper::Errors::EncryptionError }

  before do
    require_kms!
    provision(admin_conn, table: table, encrypted_columns: ['ssn'], plain_columns: ['name'])
  end

  after do
    conn && Integration::DriverHelper.close(drv, conn)
    teardown_encryption(admin_conn, table: table)
    admin_conn && Integration::DriverHelper.close(drv, admin_conn)
  rescue StandardError
    nil
  end

  # A short value that is not a valid encrypted payload, written before/around the plugin.
  it 'raises when reading a pre-encryption plaintext value' do
    insert_raw(admin_conn, 'Legacy', 'plain-legacy-value')

    expect { read_ssn(conn, 'Legacy') }.to raise_error(encryption_error)
  end

  # 80 random bytes: long enough to look like a payload by length, but its HMAC will not verify.
  it 'raises when reading a value whose integrity cannot be verified' do
    insert_raw(admin_conn, 'Tampered', SecureRandom.bytes(80))

    expect { read_ssn(conn, 'Tampered') }.to raise_error(encryption_error)
  end

  # The opt-in lenient read. Not for production; here it lets pre-existing data read back.
  context 'with encryption_return_unverified_data enabled' do
    let(:conn) do
      encryption_connect(
        AwsAdvancedRubyDriverWrapper::PropertyDefinition::ENCRYPTION_RETURN_UNVERIFIED_DATA.name => true
      )
    end

    it 'reads a pre-encryption plaintext value back untouched' do
      insert_raw(admin_conn, 'Legacy', 'plain-legacy-value')

      expect(read_ssn(conn, 'Legacy')).to eq(stored_value(admin_conn, table, 'ssn', 'name', 'Legacy'))
    end

    it 'passes a value whose integrity cannot be verified through untouched' do
      insert_raw(admin_conn, 'Tampered', SecureRandom.bytes(80))

      read = nil
      expect { read = read_ssn(conn, 'Tampered') }.not_to raise_error
      expect(read).to eq(stored_value(admin_conn, table, 'ssn', 'name', 'Tampered'))
    end
  end

  # Writes a raw value straight into the encrypted (binary) column over a plain connection, the way
  # data would arrive without the plugin.
  def insert_raw(conn, name, bytes)
    case drv
    when Integration::TestDriver::PG
      conn.exec_params("INSERT INTO #{table} (name, ssn) VALUES ($1, $2)",
                       [name, { value: bytes.b, format: 1 }])
    when Integration::TestDriver::MYSQL
      conn.query("INSERT INTO #{table} (name, ssn) VALUES ('#{conn.escape(name)}', X'#{hex(bytes)}')")
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
end
