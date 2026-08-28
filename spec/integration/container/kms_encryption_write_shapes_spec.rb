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

# Write-shape coverage. The plugin encrypts a bind parameter only when it can read, from the
# statement, which column that parameter fills, so every statement shape the plugin claims to
# support has to actually place ciphertext and read it back.
RSpec.describe 'KmsEncryption write shapes', :integration, :kms_encryption,
               enable_on_engines: [Integration::DatabaseEngine::MYSQL, Integration::DatabaseEngine::PG],
               disable_on_features: [Integration::TestEnvironmentFeatures::PERFORMANCE] do
  include Integration::KmsEncryptionHelper

  let(:table) { 'enc_writes' }
  let(:admin_conn) { native_connect }
  let(:conn) { encryption_connect }

  before do
    require_kms!
    provision(admin_conn, table: table, encrypted_columns: ['ssn'], plain_columns: ['name'])
    # A unique key on the plaintext column so upserts have something to conflict on.
    run(admin_conn, "CREATE UNIQUE INDEX #{table}_name_uq ON #{table} (name)")
  end

  after do
    conn && Integration::DriverHelper.close(drv, conn)
    teardown_encryption(admin_conn, table: table)
    admin_conn && Integration::DriverHelper.close(drv, admin_conn)
  rescue StandardError
    nil
  end

  it 'encrypts an INSERT' do
    insert(conn, 'Insert', '111-11-1111')
    expect(read_ssn(conn, 'Insert')).to eq('111-11-1111')
    expect(stored_value(admin_conn, table, 'ssn', 'name', 'Insert').to_s).not_to include('111-11-1111')
  end

  it 'encrypts an UPDATE' do
    insert(conn, 'Update', '111-11-1111')
    update_ssn(conn, 'Update', '222-22-2222')
    expect(read_ssn(conn, 'Update')).to eq('222-22-2222')
  end

  it 'encrypts a prepared statement' do
    case drv
    when Integration::TestDriver::PG
      conn.prepare('ins_stmt', "INSERT INTO #{table} (name, ssn) VALUES ($1, $2)")
      conn.exec_prepared('ins_stmt', %w[Prepared 333-33-3333])
    when Integration::TestDriver::MYSQL
      conn.prepare("INSERT INTO #{table} (name, ssn) VALUES (?, ?)").execute('Prepared', '333-33-3333')
    end
    expect(read_ssn(conn, 'Prepared')).to eq('333-33-3333')
  end

  it 'encrypts a multi-row VALUES insert' do
    case drv
    when Integration::TestDriver::PG
      conn.exec_params("INSERT INTO #{table} (name, ssn) VALUES ($1, $2), ($3, $4)",
                       %w[MultiA 444-44-4444 MultiB 555-55-5555])
    when Integration::TestDriver::MYSQL
      conn.prepare("INSERT INTO #{table} (name, ssn) VALUES (?, ?), (?, ?)")
          .execute('MultiA', '444-44-4444', 'MultiB', '555-55-5555')
    end
    expect(read_ssn(conn, 'MultiA')).to eq('444-44-4444')
    expect(read_ssn(conn, 'MultiB')).to eq('555-55-5555')
  end

  it 'encrypts an upsert assignment' do
    insert(conn, 'Upsert', '111-11-1111')
    # The update branch binds the new value directly. EXCLUDED.ssn / VALUES(ssn) are not bind
    # parameters, so the plugin (correctly) cannot encrypt through them and fails closed; the
    # supported upsert form assigns a bound value.
    case drv
    when Integration::TestDriver::PG
      conn.exec_params(
        "INSERT INTO #{table} (name, ssn) VALUES ($1, $2) " \
        'ON CONFLICT (name) DO UPDATE SET ssn = $3',
        %w[Upsert 000-00-0000 666-66-6666]
      )
    when Integration::TestDriver::MYSQL
      conn.prepare(
        "INSERT INTO #{table} (name, ssn) VALUES (?, ?) ON DUPLICATE KEY UPDATE ssn = ?"
      ).execute('Upsert', '000-00-0000', '666-66-6666')
    end
    expect(read_ssn(conn, 'Upsert')).to eq('666-66-6666')
  end

  context 'on PostgreSQL only' do
    before { skip 'PostgreSQL only' unless drv == Integration::TestDriver::PG }

    it 'encrypts a data-modifying CTE' do
      conn.exec_params(
        "WITH inserted AS (INSERT INTO #{table} (name, ssn) VALUES ($1, $2) RETURNING id) SELECT * FROM inserted",
        %w[Cte 777-77-7777]
      )
      expect(read_ssn(conn, 'Cte')).to eq('777-77-7777')
    end

    it 'encrypts a MERGE' do
      server_version = conn.exec('SHOW server_version_num').first['server_version_num'].to_i
      skip 'MERGE requires PostgreSQL 15+' if server_version < 150_000

      # The INSERT clause binds name and ssn directly ($2, $3); the source only supplies the join
      # key. Referencing s.ssn instead would not be a bind parameter, so the plugin could not encrypt
      # it and would fail closed.
      conn.exec_params(
        "MERGE INTO #{table} AS t USING (VALUES ($1::text)) AS s(join_name) " \
        'ON t.name = s.join_name ' \
        'WHEN NOT MATCHED THEN INSERT (name, ssn) VALUES ($2, $3)',
        %w[Merge Merge 888-88-8888]
      )
      expect(read_ssn(conn, 'Merge')).to eq('888-88-8888')
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

  def update_ssn(conn, name, ssn)
    case drv
    when Integration::TestDriver::PG
      conn.exec_params("UPDATE #{table} SET ssn = $1 WHERE name = $2", [ssn, name])
    when Integration::TestDriver::MYSQL
      conn.prepare("UPDATE #{table} SET ssn = ? WHERE name = ?").execute(ssn, name)
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
