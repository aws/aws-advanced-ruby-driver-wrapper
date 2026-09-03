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

# Real read-shape coverage. A decrypted value has to come back correctly however the row is read -
# as a hash keyed by column name, or as a bare array of values matched to columns by position. The
# array-shaped reads are the ones that stubbed unit tests cannot prove and where the recent
# array-decrypt fixes live, so every result-object read shape each driver offers is exercised against
# a real result object holding real ciphertext.
RSpec.describe 'KmsEncryption read shapes', :integration, :kms_encryption,
               enable_on_engines: [Integration::DatabaseEngine::MYSQL, Integration::DatabaseEngine::PG],
               disable_on_features: [Integration::TestEnvironmentFeatures::PERFORMANCE] do
  include Integration::KmsEncryptionHelper

  let(:table) { 'enc_reads' }
  # name (plaintext) is column 0, ssn (encrypted) is column 1 in every SELECT below.
  let(:rows) { { 'Alice' => '111-11-1111', 'Bob' => '222-22-2222' } }
  let(:admin_conn) { native_connect }

  before do
    require_kms!
    provision(admin_conn, table: table, encrypted_columns: ['ssn'], plain_columns: ['name'])
    conn = encryption_connect
    rows.each { |name, ssn| insert_row(conn, name, ssn) }
    Integration::DriverHelper.close(drv, conn)
  end

  after do
    teardown_encryption(admin_conn, table: table)
    admin_conn && Integration::DriverHelper.close(drv, admin_conn)
  rescue StandardError
    nil
  end

  context 'on PostgreSQL' do
    before { skip 'PostgreSQL only' unless drv == Integration::TestDriver::PG }

    let(:conn) { encryption_connect }
    let(:select_sql) { "SELECT name, ssn FROM #{table} ORDER BY name" }

    after { conn && Integration::DriverHelper.close(drv, conn) }

    it '#each yields decrypted values in hash rows' do
      decrypted = []
      # Exercising #each itself, so the block push cannot be replaced with map.
      conn.exec_params(select_sql, []).each { |row| decrypted << row['ssn'] } # rubocop:disable Style/MapIntoArray
      expect(decrypted).to contain_exactly('111-11-1111', '222-22-2222')
    end

    it '#each_row yields decrypted values in array rows' do
      decrypted = []
      conn.exec_params(select_sql, []).each_row { |row| decrypted << row[1] }
      expect(decrypted).to contain_exactly('111-11-1111', '222-22-2222')
    end

    it '#to_a returns decrypted hash rows' do
      decrypted = conn.exec_params(select_sql, []).to_a.map { |row| row['ssn'] }
      expect(decrypted).to contain_exactly('111-11-1111', '222-22-2222')
    end

    it '#[] returns a decrypted hash row' do
      expect(conn.exec_params(select_sql, [])[0]['ssn']).to eq('111-11-1111')
    end

    it '#values returns decrypted array rows' do
      decrypted = conn.exec_params(select_sql, []).values.map { |row| row[1] }
      expect(decrypted).to contain_exactly('111-11-1111', '222-22-2222')
    end

    it '#column_values decrypts a whole column by index' do
      expect(conn.exec_params(select_sql, []).column_values(1)).to contain_exactly('111-11-1111', '222-22-2222')
    end

    it '#field_values decrypts a whole column by name' do
      expect(conn.exec_params(select_sql, []).field_values('ssn')).to contain_exactly('111-11-1111', '222-22-2222')
    end

    it '#tuple returns a decrypted tuple' do
      expect(conn.exec_params(select_sql, []).tuple(0)['ssn']).to eq('111-11-1111')
    end

    it '#tuple_values returns a decrypted array tuple' do
      expect(conn.exec_params(select_sql, []).tuple_values(0)[1]).to eq('111-11-1111')
    end

    it '#getvalue decrypts a single cell' do
      expect(conn.exec_params(select_sql, []).getvalue(0, 1)).to eq('111-11-1111')
    end

    context 'in single-row (streaming) mode' do
      # stream_each* read rows off the wire one at a time; they need single-row mode set on the
      # connection after the query is sent.
      def stream_result
        conn.send_query_params(select_sql, [])
        conn.set_single_row_mode
        conn
      end

      it '#stream_each yields decrypted hash rows' do
        decrypted = []
        stream_result.get_result.stream_each { |row| decrypted << row['ssn'] }
        expect(decrypted).to include('111-11-1111')
      end

      it '#stream_each_row yields decrypted array rows' do
        decrypted = []
        stream_result.get_result.stream_each_row { |row| decrypted << row[1] }
        expect(decrypted).to include('111-11-1111')
      end

      it '#stream_each_tuple yields decrypted tuples' do
        decrypted = []
        stream_result.get_result.stream_each_tuple { |tuple| decrypted << tuple['ssn'] }
        expect(decrypted).to include('111-11-1111')
      end
    end
  end

  context 'on MySQL' do
    before { skip 'MySQL only' unless drv == Integration::TestDriver::MYSQL }

    let(:conn) { encryption_connect }
    let(:select_sql) { "SELECT name, ssn FROM #{table} ORDER BY name" }

    after { conn && Integration::DriverHelper.close(drv, conn) }

    it '#each decrypts hash rows (default mode)' do
      decrypted = []
      conn.query(select_sql).each { |row| decrypted << row['ssn'] } # rubocop:disable Style/MapIntoArray
      expect(decrypted).to contain_exactly('111-11-1111', '222-22-2222')
    end

    it '#to_a decrypts hash rows (default mode)' do
      decrypted = conn.query(select_sql).to_a.map { |row| row['ssn'] }
      expect(decrypted).to contain_exactly('111-11-1111', '222-22-2222')
    end

    it '#each decrypts array rows (as: :array)' do
      decrypted = []
      conn.query(select_sql, as: :array).each { |row| decrypted << row[1] } # rubocop:disable Style/MapIntoArray
      expect(decrypted).to contain_exactly('111-11-1111', '222-22-2222')
    end

    it '#to_a decrypts array rows (as: :array)' do
      decrypted = conn.query(select_sql, as: :array).to_a.map { |row| row[1] }
      expect(decrypted).to contain_exactly('111-11-1111', '222-22-2222')
    end
  end

  def insert_row(conn, name, ssn)
    case drv
    when Integration::TestDriver::PG
      conn.exec_params("INSERT INTO #{table} (name, ssn) VALUES ($1, $2)", [name, ssn])
    when Integration::TestDriver::MYSQL
      conn.prepare("INSERT INTO #{table} (name, ssn) VALUES (?, ?)").execute(name, ssn)
    end
  end
end
