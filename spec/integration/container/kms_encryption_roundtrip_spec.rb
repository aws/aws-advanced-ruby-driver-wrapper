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

    # The /*@encrypt:table.column*/ annotation has to survive the ActiveRecord adapter: the comment
    # stays in the SQL AR sends to the driver, and the plugin honors it to encrypt the bound value.
    # This uses a raw bound statement through the connection because that is how an application would
    # reach for an annotation - a plain create! is already parsed and encrypted without one.
    it 'honors an /*@encrypt:table.column*/ annotation on a bound value' do
      model # establishes the ActiveRecord connection
      annotated_ar_insert('Annotated', ssn)

      expect(model.find_by(name: 'Annotated').ssn.to_s).to eq(ssn)
      expect(stored_value(admin_conn, table, 'ssn', 'name', 'Annotated').to_s).not_to include(ssn)
    end

    # Encryption is randomized, so an equality finder on an encrypted column never matches - the
    # documented ActiveRecord footgun (find_by / where / validates_uniqueness_of silently find
    # nothing). Filter on a non-encrypted column instead.
    it 'never matches an equality finder on an encrypted column' do
      model.create!(name: person, ssn: ssn)

      expect(model.find_by(ssn: ssn)).to be_nil
      expect(model.where(ssn: ssn).count).to eq(0)
    end
  end

  # A real table usually encrypts more than one column. This checks that a single INSERT binding two
  # encrypted columns maps each parameter to the right column and that both read back decrypted.
  context 'with multiple encrypted columns on one row' do
    let(:multi_table) { 'enc_multi' }

    before do
      provision(admin_conn, table: multi_table, encrypted_columns: %w[ssn email], plain_columns: ['name'])
    end

    after do
      teardown_encryption(admin_conn, table: multi_table)
    rescue StandardError
      nil
    end

    it 'encrypts and reads back every encrypted column in one row' do
      email = 'alice@test.com'
      conn = encryption_connect
      insert_multi(conn, person, ssn, email)

      row = select_multi(conn, person)
      expect(row['ssn']).to eq(ssn)
      expect(row['email']).to eq(email)
      expect(stored_value(admin_conn, multi_table, 'ssn', 'name', person).to_s).not_to include(ssn)
      expect(stored_value(admin_conn, multi_table, 'email', 'name', person).to_s).not_to include(email)
    ensure
      conn && Integration::DriverHelper.close(drv, conn)
    end

    def insert_multi(conn, name, ssn_value, email_value)
      case drv
      when Integration::TestDriver::PG
        conn.exec_params("INSERT INTO #{multi_table} (name, ssn, email) VALUES ($1, $2, $3)",
                         [name, ssn_value, email_value])
      when Integration::TestDriver::MYSQL
        conn.prepare("INSERT INTO #{multi_table} (name, ssn, email) VALUES (?, ?, ?)")
            .execute(name, ssn_value, email_value)
      end
    end

    def select_multi(conn, name)
      case drv
      when Integration::TestDriver::PG
        conn.exec_params("SELECT ssn, email FROM #{multi_table} WHERE name = $1", [name]).first
      when Integration::TestDriver::MYSQL
        conn.prepare("SELECT ssn, email FROM #{multi_table} WHERE name = ?").execute(name).first
      end
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

  # Inserts through ActiveRecord's connection with the ssn value bound and marked for encryption by
  # an annotation, using each adapter's native bind placeholder. With prepared_statements on, AR
  # sends the annotated SQL and the bound values to the driver rather than inlining them.
  def annotated_ar_insert(name, ssn_value)
    name_ph, ssn_ph = drv == Integration::TestDriver::PG ? %w[$1 $2] : %w[? ?]
    sql = "INSERT INTO #{table} (name, ssn) VALUES (#{name_ph}, /*@encrypt:#{table}.ssn*/ #{ssn_ph})"
    ActiveRecord::Base.connection.exec_insert(sql, 'annotated insert',
                                              [query_attribute('name', name), query_attribute('ssn', ssn_value)])
  end

  def query_attribute(name, value)
    ActiveRecord::Relation::QueryAttribute.new(name, value, ActiveRecord::Type::String.new)
  end
end
