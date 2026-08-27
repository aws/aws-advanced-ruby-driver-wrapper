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

require 'active_record'
require_relative 'integration_helper'
require_relative 'utils/test_environment'
require_relative 'utils/test_environment_features'
require_relative 'utils/test_driver'
require_relative 'utils/driver_helper'
require_relative 'utils/kms_encryption_helper'
require 'aws_advanced_ruby_driver_wrapper'
require 'aws_advanced_ruby_driver_wrapper/active_record/aws_mysql2_adapter'
require 'aws_advanced_ruby_driver_wrapper/active_record/aws_postgresql_adapter'

# Core round-trip confidence for the kms_encryption plugin: on both engines and through both
# consumption paths (the raw wrapper client and the ActiveRecord adapter), a value written to an
# encrypted column reads back decrypted, while the value at rest - read over a connection that does
# not have the plugin - is ciphertext rather than the plaintext that was written. This mirrors the
# JDBC wrapper's testBasicEncryption and testDataSourceEncryptionVerifyStoredEncrypted.
RSpec.describe 'KmsEncryption round-trip', :integration, :kms_encryption,
               enable_on_engines: [Integration::DatabaseEngine::MYSQL, Integration::DatabaseEngine::PG],
               disable_on_features: [Integration::TestEnvironmentFeatures::PERFORMANCE] do
  include Integration::KmsEncryptionHelper

  let(:table) { 'enc_users' }
  let(:ssn) { '111-11-1111' }
  let(:person) { 'Alice Test' }

  let(:admin_conn) { native_connect }

  before do
    require_kms!
    provision(admin_conn, table: table, encrypted_columns: ['ssn'], plain_columns: ['name'])
  end

  after do
    teardown_encryption(admin_conn, table: table)
    admin_conn && Integration::DriverHelper.close(drv, admin_conn)
    ActiveRecord::Base.connection_handler.clear_all_connections!
  rescue StandardError
    nil
  end

  context 'through the raw wrapper client' do
    it 'writes an encrypted value and reads it back decrypted' do
      conn = encryption_connect
      insert_person(conn, person, ssn)

      expect(select_ssn(conn, person)).to eq(ssn)
    ensure
      conn && Integration::DriverHelper.close(drv, conn)
    end

    it 'stores the value as ciphertext, not plaintext' do
      conn = encryption_connect
      insert_person(conn, person, ssn)
      Integration::DriverHelper.close(drv, conn)

      at_rest = stored_value(admin_conn, table, 'ssn', 'name', person)
      expect(at_rest).not_to be_nil
      expect(at_rest.to_s).not_to include(ssn)
    end
  end

  context 'through the ActiveRecord adapter' do
    # The decrypted value comes back as a string, so the model treats the binary column as a string
    # rather than letting ActiveRecord run bytea/binary deserialization over an already-decrypted
    # value.
    let(:model) do
      ActiveRecord::Base.establish_connection(encryption_adapter_config)
      Class.new(ActiveRecord::Base) do
        self.table_name = 'enc_users'
        self.inheritance_column = nil
        attribute :ssn, :string
      end
    end

    it 'writes an encrypted value and reads it back decrypted' do
      model.create!(name: person, ssn: ssn)

      expect(model.find_by(name: person).ssn.to_s).to eq(ssn)
    end

    it 'stores the value as ciphertext, not plaintext' do
      model.create!(name: person, ssn: ssn)

      at_rest = stored_value(admin_conn, table, 'ssn', 'name', person)
      expect(at_rest).not_to be_nil
      expect(at_rest.to_s).not_to include(ssn)
    end
  end

  # -- write/read helpers, per driver --

  def insert_person(conn, name, ssn_value)
    case drv
    when Integration::TestDriver::PG
      conn.exec_params("INSERT INTO #{table} (name, ssn) VALUES ($1, $2)", [name, ssn_value])
    when Integration::TestDriver::MYSQL
      conn.prepare("INSERT INTO #{table} (name, ssn) VALUES (?, ?)").execute(name, ssn_value)
    end
  end

  def select_ssn(conn, name)
    case drv
    when Integration::TestDriver::PG
      conn.exec_params("SELECT ssn FROM #{table} WHERE name = $1", [name]).first['ssn']
    when Integration::TestDriver::MYSQL
      conn.prepare("SELECT ssn FROM #{table} WHERE name = ?").execute(name).first['ssn']
    end
  end
end
