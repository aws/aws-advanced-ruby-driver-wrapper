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

require 'bigdecimal'
require 'date'
require 'time'
require_relative 'integration_helper'
require_relative 'utils/test_environment'
require_relative 'utils/test_environment_features'
require_relative 'utils/test_driver'
require_relative 'utils/driver_helper'
require_relative 'utils/kms_encryption_helper'
require 'aws_advanced_ruby_driver_wrapper'

# Type coverage for the kms_encryption plugin. Every supported type is written through an encrypted
# column as its native Ruby value and read back. A decrypted value always comes back as a string
# (the plugin serializes by type on write and coerces to String on read, so the read is consistent
# with the binary column's real type), so each case asserts both that the read value is a String and
# that it carries the original value faithfully.
RSpec.describe 'KmsEncryption type coverage', :integration, :kms_encryption,
               enable_on_engines: [Integration::DatabaseEngine::MYSQL, Integration::DatabaseEngine::PG],
               disable_on_features: [Integration::TestEnvironmentFeatures::PERFORMANCE] do
  include Integration::KmsEncryptionHelper

  let(:table) { 'enc_types' }
  let(:admin_conn) { native_connect }

  before do
    require_kms!
    create_metadata_tables(admin_conn)
    create_app_table(admin_conn, table, encrypted_columns: ['secret'], plain_columns: ['label'])
    configure_column(admin_conn, table, 'secret')
  end

  after do
    teardown_encryption(admin_conn, table: table)
    admin_conn && Integration::DriverHelper.close(drv, admin_conn)
  rescue StandardError
    nil
  end

  it 'round-trips a string' do
    result = roundtrip('string', 'hello world')
    expect(result).to be_a(String)
    expect(result).to eq('hello world')
  end

  it 'round-trips an integer' do
    result = roundtrip('integer', 42)
    expect(result).to be_a(String)
    expect(result).to eq('42')
  end

  it 'round-trips a large (long) integer' do
    value = 9_000_000_000
    result = roundtrip('long', value)
    expect(result).to eq(value.to_s)
  end

  it 'round-trips a float/double' do
    result = roundtrip('double', 3.14159)
    expect(result.to_f).to be_within(1e-9).of(3.14159)
  end

  it 'round-trips a BigDecimal' do
    result = roundtrip('bigdecimal', BigDecimal('12345.6789'))
    expect(BigDecimal(result)).to eq(BigDecimal('12345.6789'))
  end

  it 'round-trips a true boolean' do
    expect(roundtrip('bool_true', true)).to eq('true')
  end

  it 'round-trips a false boolean' do
    expect(roundtrip('bool_false', false)).to eq('false')
  end

  it 'round-trips a date' do
    value = Date.new(2024, 3, 14)
    result = roundtrip('date', value)
    expect(Date.parse(result)).to eq(value)
  end

  it 'round-trips a datetime' do
    value = DateTime.new(2024, 3, 14, 9, 26, 53)
    result = roundtrip('datetime', value)
    expect(DateTime.parse(result)).to eq(value)
  end

  it 'round-trips a timestamp (Time)' do
    value = Time.utc(2024, 3, 14, 9, 26, 53)
    result = roundtrip('timestamp', value)
    # Time is stored to millisecond precision.
    expect(Time.parse(result)).to be_within(0.001).of(value)
  end

  it 'round-trips a byte array' do
    value = "\x00\x01\x02\xFF".b
    result = roundtrip('bytes', value)
    expect(result.b).to eq(value)
  end

  # A NULL bind is not a value to encrypt: the plugin leaves it alone on write and hands back nil on
  # read, so a nullable encrypted column behaves normally.
  it 'round-trips a NULL as nil' do
    expect(roundtrip('null_case', nil)).to be_nil
  end

  # Inserts a typed value into the encrypted column under a unique label and reads it back decrypted.
  def roundtrip(label, value)
    conn = encryption_connect
    insert_secret(conn, label, value)
    select_secret(conn, label)
  ensure
    conn && Integration::DriverHelper.close(drv, conn)
  end

  def insert_secret(conn, label, value)
    case drv
    when Integration::TestDriver::PG
      conn.exec_params("INSERT INTO #{table} (label, secret) VALUES ($1, $2)", [label, value])
    when Integration::TestDriver::MYSQL
      conn.prepare("INSERT INTO #{table} (label, secret) VALUES (?, ?)").execute(label, value)
    end
  end

  def select_secret(conn, label)
    case drv
    when Integration::TestDriver::PG
      conn.exec_params("SELECT secret FROM #{table} WHERE label = $1", [label]).first['secret']
    when Integration::TestDriver::MYSQL
      conn.prepare("SELECT secret FROM #{table} WHERE label = ?").execute(label).first['secret']
    end
  end
end
