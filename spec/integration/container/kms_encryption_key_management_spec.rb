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

# KeyManagementUtility against real KMS: creating a master key, turning encryption on for a column,
# validating the metadata schema, and rotating a data key. This drives the administrative side over
# its own connections, exactly as a migration or setup script would.
#
# Rotation changes only which key new writes use. A value written before a rotation still decrypts
# afterwards, because its payload records the id of the key it was written with and the read path
# resolves that key from key_storage (which retains the old key).
RSpec.describe 'KmsEncryption key management', :integration, :kms_encryption,
               enable_on_engines: [Integration::DatabaseEngine::MYSQL, Integration::DatabaseEngine::PG],
               disable_on_features: [Integration::TestEnvironmentFeatures::PERFORMANCE] do
  include Integration::KmsEncryptionHelper

  let(:key_error) { AwsAdvancedRubyDriverWrapper::Errors::KeyManagementError }
  let(:table) { 'enc_key_mgmt' }
  let(:admin_conn) { native_connect }
  # The administrative interface (create/rotate keys, enable columns) lives on KeyManagementUtility,
  # reached through the KmsEncryptionUtility that build_encryption_utility returns. Schema validation
  # stays on the KmsEncryptionUtility itself.
  let(:kmu) { @utility.key_management_utility }

  before do
    require_kms!
    create_metadata_tables(admin_conn)
    create_app_table(admin_conn, table, encrypted_columns: ['ssn'], plain_columns: ['name'])
    @container, @utility = build_encryption_utility
  end

  after do
    @utility&.cleanup
    container_conn = @container&.connection_service&.current_connection
    container_conn && Integration::DriverHelper.close(drv, container_conn)
    teardown_encryption(admin_conn, table: table)
    admin_conn && Integration::DriverHelper.close(drv, admin_conn)
  rescue StandardError
    nil
  end

  it 'validates a well-formed metadata schema' do
    result = @utility.validate_schema
    expect(result.valid?).to be(true), -> { "schema validation failed: #{result.issues.join(', ')}" }
  end

  it 'creates a KMS master key when permitted' do
    arn = begin
      kmu.create_master_key('aws-advanced-ruby-driver-wrapper integration test key')
    rescue key_error => e
      skip "master key creation is not permitted in this environment: #{e.message}"
    end

    expect(arn).to match(/\Aarn:aws:kms:/)
    # Do not leave the key lying around; schedule it for deletion (minimum 7-day window).
    schedule_key_deletion(arn)
  end

  it 'turns encryption on for a column and round-trips a value through it' do
    kmu.initialize_encryption_for_column(table, 'ssn', kms_key_id)

    conn = encryption_connect
    write_ssn(conn, 'Enabled', '111-11-1111')
    expect(read_ssn(conn, 'Enabled')).to eq('111-11-1111')
    expect(stored_value(admin_conn, table, 'ssn', 'name', 'Enabled').to_s).not_to include('111-11-1111')
  ensure
    conn && Integration::DriverHelper.close(drv, conn)
  end

  it 'rotates the data key, keeping old values readable while new writes use the new key' do
    original_key_id = kmu.initialize_encryption_for_column(table, 'ssn', kms_key_id)

    # A value written before the rotation.
    before_conn = encryption_connect
    write_ssn(before_conn, 'Before', '111-11-1111')
    expect(read_ssn(before_conn, 'Before')).to eq('111-11-1111')
    Integration::DriverHelper.close(drv, before_conn)

    new_key_id = kmu.rotate_data_key(table, 'ssn', kms_key_id)
    expect(new_key_id).not_to eq(original_key_id)

    # A value written after the rotation round-trips through the new key.
    after_conn = encryption_connect
    write_ssn(after_conn, 'After', '222-22-2222')
    expect(read_ssn(after_conn, 'After')).to eq('222-22-2222')

    # The pre-rotation value still decrypts: its payload names the key it was written with, and
    # rotation leaves that key in key_storage.
    expect(read_ssn(after_conn, 'Before')).to eq('111-11-1111')
  ensure
    after_conn && Integration::DriverHelper.close(drv, after_conn)
  end

  it 'reports the columns a stored key is used by' do
    key_id = kmu.initialize_encryption_for_column(table, 'ssn', kms_key_id)
    expect(kmu.columns_using_key(key_id)).to include("#{table}.ssn")
  end

  def schedule_key_deletion(arn)
    kms_client.schedule_key_deletion(key_id: arn, pending_window_in_days: 7)
  rescue StandardError
    nil
  end

  def write_ssn(conn, name, ssn)
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
end
