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

# Documented behaviors of the plugin that only show up against a real database: randomized
# encryption defeating equality search, the annotation escape hatch, failing closed on a literal
# into an encrypted column, and passing an unreadable write through to the database.
RSpec.describe 'KmsEncryption documented behaviors', :integration, :kms_encryption,
               enable_on_engines: [Integration::DatabaseEngine::MYSQL, Integration::DatabaseEngine::PG],
               disable_on_features: [Integration::TestEnvironmentFeatures::PERFORMANCE] do
  include Integration::KmsEncryptionHelper

  let(:table) { 'enc_behaviors' }
  let(:admin_conn) { native_connect }
  let(:conn) { encryption_connect }

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

  it 'returns no rows for an equality search on an encrypted column (randomized encryption)' do
    insert(conn, 'Alice', '111-11-1111')

    matched =
      case drv
      when Integration::TestDriver::PG
        conn.exec_params("SELECT name FROM #{table} WHERE ssn = $1", ['111-11-1111']).to_a
      when Integration::TestDriver::MYSQL
        conn.prepare("SELECT name FROM #{table} WHERE ssn = ?").execute('111-11-1111').to_a
      end

    expect(matched).to be_empty
  end

  it 'encrypts a value marked with an /*@encrypt:table.column*/ annotation' do
    case drv
    when Integration::TestDriver::PG
      conn.exec_params("INSERT INTO #{table} (name, ssn) VALUES ($1, /*@encrypt:#{table}.ssn*/ $2)",
                       %w[Annotated 123-45-6789])
    when Integration::TestDriver::MYSQL
      conn.prepare("INSERT INTO #{table} (name, ssn) VALUES (?, /*@encrypt:#{table}.ssn*/ ?)")
          .execute('Annotated', '123-45-6789')
    end

    expect(read_ssn(conn, 'Annotated')).to eq('123-45-6789')
    expect(stored_value(admin_conn, table, 'ssn', 'name', 'Annotated').to_s).not_to include('123-45-6789')
  end

  it 'fails closed on a literal written into an encrypted column' do
    expect do
      case drv
      when Integration::TestDriver::PG
        conn.exec("INSERT INTO #{table} (name, ssn) VALUES ('Literal', '999-99-9999')")
      when Integration::TestDriver::MYSQL
        conn.query("INSERT INTO #{table} (name, ssn) VALUES ('Literal', '999-99-9999')")
      end
    end.to raise_error(AwsAdvancedRubyDriverWrapper::Errors::MetadataError)

    # The refused write stored nothing.
    expect(count_rows(admin_conn, 'Literal')).to eq(0)
  end

  it 'passes an unreadable write (values from a nested SELECT) through to the database' do
    insert(conn, 'Seed', '111-11-1111')

    # The plugin cannot establish which columns a SELECT-sourced insert writes, so it leaves the
    # statement to the database rather than refusing it. The copied value is already ciphertext.
    expect do
      case drv
      when Integration::TestDriver::PG
        conn.exec("INSERT INTO #{table} (name, ssn) SELECT 'Copied', ssn FROM #{table} WHERE name = 'Seed'")
      when Integration::TestDriver::MYSQL
        conn.query("INSERT INTO #{table} (name, ssn) SELECT 'Copied', ssn FROM #{table} WHERE name = 'Seed'")
      end
    end.not_to raise_error

    expect(read_ssn(conn, 'Copied')).to eq('111-11-1111')
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
