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

require_relative '../../../spec_helper'
require 'aws_advanced_ruby_driver_wrapper/plugins/kms_encryption/audit_logger'

RSpec.describe AwsAdvancedRubyDriverWrapper::Plugins::Encryption::AuditLogger do
  subject(:audit) { described_class.new(true) }

  let(:written) { [] }

  before do
    logger = AwsAdvancedRubyDriverWrapper.logger
    %i[debug info warn].each do |level|
      allow(logger).to receive(level) { |line| written << [level, line] }
    end
  end

  def line
    written.last&.last
  end

  def level
    written.last&.first
  end

  # Every record is one line of key=value fields, so that an audit trail can be grepped.
  describe 'the record format' do
    it 'names the operation and the outcome' do
      audit.log_encryption(table_name: 'users', column_name: 'ssn')
      expect(line).to start_with('AUDIT operation=ENCRYPTION success=true ')
    end

    it 'stamps every record with a UTC timestamp' do
      audit.log_encryption(table_name: 'users', column_name: 'ssn')
      expect(line).to match(/ timestamp=\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$/)
    end

    it 'leaves out the fields it has no value for' do
      audit.log_encryption(table_name: 'users', column_name: 'ssn')
      expect(line).not_to include('key_id=')
    end

    it 'logs a successful operation at info level' do
      audit.log_encryption(table_name: 'users', column_name: 'ssn')
      expect(level).to eq(:info)
    end

    it 'logs a failure at warn level, with its reason' do
      audit.log_encryption(table_name: 'users', column_name: 'ssn', success: false,
                           error_message: 'the data key was rejected')

      expect(level).to eq(:warn)
      expect(line).to include('success=false', 'error=the data key was rejected')
    end
  end

  describe 'when audit logging is disabled' do
    subject(:audit) { described_class.new(false) }

    it 'says so' do
      expect(audit.enabled?).to be(false)
    end

    it 'writes nothing at all' do
      audit.log_key_creation(master_key_arn: 'arn:aws:kms:us-east-1:1:key/abcd')
      audit.log_data_key_generation(master_key_arn: 'arn')
      audit.log_data_key_decryption(master_key_arn: 'arn')
      audit.log_encryption(table_name: 'users', column_name: 'ssn')
      audit.log_decryption(table_name: 'users', column_name: 'ssn')
      audit.log_metadata_operation(operation: 'load')
      audit.log_configuration_change(config_type: 'plugin')
      audit.log_connection_parameter_extraction(strategy: 'copy', connection_type: 'independent')
      audit.log_connection_sharing_fallback(reason: 'no host')
      audit.log_connection_health_check(connection_type: 'independent', healthy: true, success_count: 1,
                                        failure_count: 0, success_rate: 1.0)

      expect(written).to be_empty
    end
  end

  describe 'key management records' do
    it 'records a master key being created' do
      audit.log_key_creation(master_key_arn: 'arn:aws:kms:us-east-1:123456789012:key/abcd',
                             description: 'ruby wrapper key')

      expect(line).to include('operation=KEY_CREATION', 'master_key_arn=arn:aws:kms:***:***:key/***',
                              'description=ruby wrapper key')
    end

    it 'records a data key being generated' do
      audit.log_data_key_generation(master_key_arn: 'arn:aws:kms:us-east-1:123456789012:key/abcd',
                                    key_id: '1234abcd-12ab-34cd')

      expect(line).to include('operation=DATA_KEY_GENERATION', 'key_id=1234***34cd')
    end

    it 'records a data key being decrypted' do
      audit.log_data_key_decryption(master_key_arn: 'arn:aws:kms:us-east-1:123456789012:key/abcd')
      expect(line).to include('operation=DATA_KEY_DECRYPTION')
    end
  end

  describe 'column records' do
    it 'records a column being encrypted' do
      audit.log_encryption(table_name: 'users', column_name: 'ssn', key_id: '1234abcd-12ab-34cd')
      expect(line).to include('operation=ENCRYPTION', 'table=users', 'column=ssn', 'key_id=1234***34cd')
    end

    it 'records a column being decrypted' do
      audit.log_decryption(table_name: 'users', column_name: 'ssn')
      expect(line).to include('operation=DECRYPTION', 'table=users', 'column=ssn')
    end

    # The audit trail records which column was touched, never the value that was in it.
    it 'never records the column value' do
      audit.log_encryption(table_name: 'users', column_name: 'ssn', success: false,
                           error_message: "Failed to encrypt '123-45-6789' with password=hunter2")

      expect(line).to include('password=***')
      expect(line).not_to include('hunter2')
    end
  end

  describe 'metadata records' do
    it 'names the metadata operation' do
      audit.log_metadata_operation(operation: 'refresh')
      expect(line).to include('operation=METADATA_REFRESH')
    end

    it 'names the column when the operation was about one' do
      audit.log_metadata_operation(operation: 'lookup', table_name: 'users', column_name: 'ssn')
      expect(line).to include('operation=METADATA_LOOKUP', 'table=users', 'column=ssn')
    end
  end

  describe 'configuration records' do
    it 'records what changed' do
      audit.log_configuration_change(config_type: 'column_encryption', details: 'users.ssn enabled')
      expect(line).to include('operation=CONFIGURATION_CHANGE', 'config_type=column_encryption',
                              'details=users.ssn enabled')
    end

    it 'masks credentials in the details' do
      audit.log_configuration_change(config_type: 'plugin', details: '{user=jo, password=hunter2}')
      expect(line).to include('password=***')
      expect(line).not_to include('hunter2')
    end

    it 'records how the connection parameters were obtained' do
      audit.log_connection_parameter_extraction(strategy: 'copy_from_current', connection_type: 'independent')
      expect(line).to include('operation=CONNECTION_PARAMETER_EXTRACTION', 'strategy=copy_from_current',
                              'connection_type=independent')
    end
  end

  describe 'connection records' do
    it 'records a fallback to connection sharing at debug level' do
      audit.log_connection_sharing_fallback(reason: 'no independent host', original_failure: 'ECONNREFUSED',
                                            active: true)

      expect(level).to eq(:debug)
      expect(line).to include('operation=CONNECTION_SHARING_FALLBACK', 'reason=no independent host',
                              'original_failure=ECONNREFUSED', 'active=true')
    end

    # The fallback deactivating - going back to a dedicated connection - is a state change worth
    # surfacing at info, unlike the steady state while it is active.
    it 'records connection sharing being deactivated at info level' do
      audit.log_connection_sharing_fallback(reason: 'independent host recovered', active: false)

      expect(level).to eq(:info)
      expect(line).to include('operation=CONNECTION_SHARING_FALLBACK', 'active=false')
    end

    it 'records a healthy connection at info level with its success rate' do
      audit.log_connection_health_check(connection_type: 'independent', healthy: true, success_count: 9,
                                        failure_count: 1, success_rate: 0.9)

      expect(level).to eq(:info)
      expect(line).to include('operation=CONNECTION_HEALTH_CHECK', 'healthy=true', 'successful=9', 'failed=1',
                              'success_rate=90.00%')
    end

    it 'records an unhealthy connection at warn level' do
      audit.log_connection_health_check(connection_type: 'independent', healthy: false, success_count: 1,
                                        failure_count: 9, success_rate: 0.1)

      expect(level).to eq(:warn)
      expect(line).to include('success=false', 'healthy=false', 'success_rate=10.00%')
    end
  end
end
