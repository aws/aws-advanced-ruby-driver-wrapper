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
require 'aws_ruby_database_driver_wrapper/plugins/encryption/errors'

RSpec.describe AwsRubyDatabaseDriverWrapper::Errors::EncryptionPluginError do
  let(:errors) { AwsRubyDatabaseDriverWrapper::Errors }

  describe 'the shared behaviour' do
    subject(:error) { errors::EncryptionError.new('Cipher rejected the key') }

    it 'is a wrapper error, so a caller that rescues StandardError still catches it' do
      expect(error).to be_a(AwsRubyDatabaseDriverWrapper::Errors::AwsError)
      expect(error).to be_a(StandardError)
    end

    it 'keeps the message it was given, without any context' do
      expect(error.base_message).to eq('Cipher rejected the key')
      expect(error.to_s).to eq('Cipher rejected the key')
    end

    it 'falls back to the subclass default code' do
      expect(error.code).to eq(errors::EncryptionError::ENCRYPTION_FAILED)
    end

    it 'appends the accumulated context to the message' do
      error.with_table('users').with_column('ssn').with_operation('ENCRYPT')
      expect(error.to_s).to eq('Cipher rejected the key [Context: table=users, column=ssn, operation=ENCRYPT]')
    end

    # Exception#message reads to_s, so the context reaches whatever logs the failure.
    it 'includes the context in the raised message' do
      expect { raise error.with_table('users') }
        .to raise_error(errors::EncryptionError, /Cipher rejected the key \[Context: table=users\]/)
    end

    it 'ignores context entries with no value, so unknown details are simply absent' do
      error.with_context(:table, nil).with_column(nil)
      expect(error.context).to be_empty
      expect(error.to_s).to eq('Cipher rejected the key')
    end

    it 'returns itself from every with_ helper, so the calls can be chained' do
      expect(error.with_context(:a, 1)).to be(error)
      expect(error.with_operation('ENCRYPT')).to be(error)
      expect(error.with_table('users')).to be(error)
    end

    it 'accepts a starting context' do
      expect(errors::EncryptionError.encryption_failed('boom', { table: 'users' }).context).to eq({ table: 'users' })
    end

    it 'accepts an explicit code' do
      expect(errors::EncryptionError.new('boom', code: 'ENC99').code).to eq('ENC99')
    end
  end

  describe AwsRubyDatabaseDriverWrapper::Errors::EncryptionError do
    it 'gives each failure a stable code' do
      expect(described_class.encryption_failed('x').code).to eq('ENC01')
      expect(described_class.decryption_failed('x').code).to eq('ENC02')
      expect(described_class.invalid_algorithm('x').code).to eq('ENC03')
      expect(described_class.invalid_key('x').code).to eq('ENC04')
      expect(described_class.type_conversion_failed('x').code).to eq('ENC05')
    end

    it 'records the column it failed on' do
      error = described_class.encryption_failed('x').with_table('users').with_column('ssn')
      expect(error.context).to eq({ table: 'users', column: 'ssn' })
    end

    it 'redacts an over-long table or column name' do
      error = described_class.encryption_failed('x').with_table('t' * 60)
      expect(error.context[:table]).to end_with('...')
      expect(error.context[:table].length).to eq(50)
    end

    it 'records the algorithm and the data type' do
      error = described_class.decryption_failed('x').with_algorithm('AES-256-GCM').with_data_type('BIG_DECIMAL')
      expect(error.context).to eq({ algorithm: 'AES-256-GCM', data_type: 'BIG_DECIMAL' })
    end
  end

  describe AwsRubyDatabaseDriverWrapper::Errors::KeyManagementError do
    it 'gives each failure a stable code' do
      expect(described_class.key_creation_failed('x').code).to eq('KEY01')
      expect(described_class.key_retrieval_failed('x').code).to eq('KEY02')
      expect(described_class.key_decryption_failed('x').code).to eq('KEY03')
      expect(described_class.key_storage_failed('x').code).to eq('KEY04')
      expect(described_class.kms_connection_failed('x').code).to eq('KEY05')
      expect(described_class.invalid_key_metadata('x').code).to eq('KEY06')
    end

    it 'defaults to the retrieval code' do
      expect(described_class.new('x').code).to eq('KEY02')
    end

    it 'masks the key id' do
      error = described_class.key_retrieval_failed('x').with_key_id('1234abcd-12ab-34cd-56ef-1234567890ab')
      expect(error.context[:key_id]).to eq('1234***90ab')
    end

    # An ARN names the account, so only the key id is kept.
    it 'masks the account and region of the master key ARN' do
      error = described_class.key_decryption_failed('x')
                             .with_master_key_arn('arn:aws:kms:us-east-1:123456789012:key/1234abcd-56ef')
      expect(error.context[:master_key_arn]).to eq('arn:aws:kms:***:***:key/1234abcd-56ef')
    end

    it 'records which retry failed' do
      expect(described_class.kms_connection_failed('x').with_retry_info(2, 3).context[:retry_attempt]).to eq('2/3')
    end
  end

  describe AwsRubyDatabaseDriverWrapper::Errors::MetadataError do
    it 'gives each failure a stable code' do
      expect(described_class.load_failed('x').code).to eq('META01')
      expect(described_class.cache_failed('x').code).to eq('META02')
      expect(described_class.refresh_failed('x').code).to eq('META03')
      expect(described_class.lookup_failed('x').code).to eq('META04')
      expect(described_class.validation_failed('x').code).to eq('META05')
    end

    it 'defaults to the lookup code' do
      expect(described_class.new('x').code).to eq('META04')
    end

    it 'records the column it was looking up' do
      error = described_class.lookup_failed('x').with_table('users').with_column('ssn')
      expect(error.context).to eq({ table: 'users', column: 'ssn' })
    end

    it 'records a cache miss as well as a hit' do
      expect(described_class.cache_failed('x').with_cache_info('metadata', false).context)
        .to eq({ cache_type: 'metadata', cache_hit: false })
    end

    it 'masks the literals of the SQL it was running' do
      error = described_class.load_failed('x').with_sql("SELECT * FROM users WHERE ssn = '123-45-6789'")
      expect(error.context[:sql]).to eq("SELECT * FROM users WHERE ssn = '***'")
    end
  end

  describe AwsRubyDatabaseDriverWrapper::Errors::IndependentConnectionError do
    it 'describes the failure on its own' do
      expect(described_class.new.message).to eq('Independent connection creation failed')
    end

    it 'names the operation, the cause, and the reason' do
      error = described_class.new('the host refused the connection',
                                  connection_attempt: 'metadata refresh',
                                  failure_reason: 'ECONNREFUSED')
      expect(error.message).to eq(
        'Independent connection creation failed while attempting: metadata refresh - ' \
        'the host refused the connection (reason: ECONNREFUSED)'
      )
    end

    it 'masks the credentials of the target it tried to reach' do
      error = described_class.new(attempted_parameters: 'postgres://jo:hunter2@db.example.com/app')
      expect(error.message).to eq(
        'Independent connection creation failed (attempted target: postgres://***:***@db.example.com/app)'
      )
    end

    it 'keeps the details available to the caller' do
      error = described_class.new('boom', attempted_parameters: { host: 'db' },
                                          connection_attempt: 'metadata refresh', failure_reason: 'ECONNREFUSED')
      expect(error.attempted_parameters).to eq({ host: 'db' })
      expect(error.connection_attempt).to eq('metadata refresh')
      expect(error.failure_reason).to eq('ECONNREFUSED')
    end
  end
end
