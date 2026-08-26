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
require 'aws-sdk-kms'
require 'aws_ruby_database_driver_wrapper/plugins/kms_encryption/encryption_config'
require 'aws_ruby_database_driver_wrapper/plugins/kms_encryption/independent_connection_provider'
require 'aws_ruby_database_driver_wrapper/plugins/kms_encryption/key_management_utility'
require 'aws_ruby_database_driver_wrapper/plugins/kms_encryption/key_manager'
require 'aws_ruby_database_driver_wrapper/plugins/kms_encryption/metadata_manager'
require 'aws_ruby_database_driver_wrapper/plugins/kms_encryption/sql_runner'

RSpec.describe AwsRubyDatabaseDriverWrapper::Plugins::Encryption::KeyManagementUtility do
  let(:encryption) { AwsRubyDatabaseDriverWrapper::Plugins::Encryption }
  let(:key_error) { AwsRubyDatabaseDriverWrapper::Errors::KeyManagementError }
  let(:metadata_error) { AwsRubyDatabaseDriverWrapper::Errors::MetadataError }
  let(:master_key_arn) { 'arn:aws:kms:us-east-1:123456789012:key/abcd' }
  let(:kms_client) { instance_double(Aws::KMS::Client) }
  let(:key_manager) { instance_double(encryption::KeyManager) }
  let(:metadata_manager) { instance_double(encryption::MetadataManager) }
  let(:connection_provider) { instance_double(encryption::IndependentConnectionProvider) }
  let(:sql_runner) { instance_double(encryption::SqlRunner, pg?: true) }
  let(:connection) { double('Connection') }
  let(:config) { build_encryption_config }
  let(:plaintext_key) { +('a' * 32) }
  let(:generated_key) do
    encryption::KeyManager::GeneratedDataKey.new(plaintext: plaintext_key, encrypted_data_key: 'AQIDAHj...',
                                                 hmac_key: 'h' * 32)
  end
  subject(:utility) do
    described_class.new(key_manager: key_manager, metadata_manager: metadata_manager,
                        connection_provider: connection_provider, sql_runner: sql_runner, kms_client: kms_client,
                        config: config)
  end

  before do
    allow(connection_provider).to receive(:with_connection).and_yield(connection)
    allow(metadata_manager).to receive(:refresh)
    allow(key_manager).to receive(:generate_data_key).and_return(generated_key)
    allow(key_manager).to receive(:store_key_metadata) { |metadata| metadata.with(id: 7) }
    allow(sql_runner).to receive(:update).and_return(1)
    allow(sql_runner).to receive(:upsert_clause).and_return('ON CONFLICT (table_name, column_name) DO UPDATE')
    allow(AwsRubyDatabaseDriverWrapper.logger).to receive(:info)
    allow(AwsRubyDatabaseDriverWrapper.logger).to receive(:warn)
  end

  describe '#create_master_key' do
    let(:create_key_response) { double('CreateKeyResponse', key_metadata: double('KeyMetadata', arn: master_key_arn)) }

    before do
      allow(kms_client).to receive(:create_key).and_return(create_key_response)
      allow(kms_client).to receive(:create_alias)
    end

    it 'creates a symmetric encrypt and decrypt key' do
      expect(utility.create_master_key('column kms_encryption')).to eq(master_key_arn)
      expect(kms_client).to have_received(:create_key)
        .with(description: 'column kms_encryption', key_usage: 'ENCRYPT_DECRYPT', key_spec: 'SYMMETRIC_DEFAULT')
    end

    it 'applies a key policy when one was given' do
      utility.create_master_key('column kms_encryption', key_policy: '{"Version":"2012-10-17"}')
      expect(kms_client).to have_received(:create_key).with(hash_including(policy: '{"Version":"2012-10-17"}'))
    end

    it 'lets KMS apply its default policy when none was given' do
      utility.create_master_key('column kms_encryption', key_policy: '   ')
      expect(kms_client).to have_received(:create_key).with(hash_excluding(:policy))
    end

    it 'gives the key an alias' do
      utility.create_master_key('column kms_encryption')
      expect(kms_client).to have_received(:create_alias)
        .with(alias_name: start_with(described_class::ALIAS_PREFIX), target_key_id: master_key_arn)
    end

    it 'can be asked not to create an alias' do
      utility.create_master_key('column kms_encryption', create_alias: false)
      expect(kms_client).not_to have_received(:create_alias)
    end

    # The key is usable by ARN whether or not it has an alias, so a failed alias is only a warning.
    it 'keeps the key when the alias could not be created' do
      allow(kms_client).to receive(:create_alias).and_raise(StandardError, 'AlreadyExistsException')

      expect(utility.create_master_key('column kms_encryption')).to eq(master_key_arn)
      expect(AwsRubyDatabaseDriverWrapper.logger).to have_received(:warn)
        .with(/could not create an alias for it: AlreadyExistsException/)
    end

    it 'needs a description' do
      expect { utility.create_master_key(nil) }.to raise_error(ArgumentError, /description is required/)
    end

    it 'reports a KMS refusal' do
      allow(kms_client).to receive(:create_key).and_raise(StandardError, 'AccessDeniedException')

      expect { utility.create_master_key('column kms_encryption') }
        .to raise_error(key_error, /Failed to create the master key: AccessDeniedException/)
    end

    it 'records the new key in the audit trail' do
      audit_logger = instance_double(encryption::AuditLogger)
      allow(audit_logger).to receive(:log_key_creation)
      utility = described_class.new(key_manager: key_manager, metadata_manager: metadata_manager,
                                    connection_provider: connection_provider, sql_runner: sql_runner,
                                    kms_client: kms_client, config: config, audit_logger: audit_logger)

      utility.create_master_key('column kms_encryption')

      expect(audit_logger).to have_received(:log_key_creation)
        .with(master_key_arn: master_key_arn, description: 'column kms_encryption', success: true)
    end
  end

  describe '#initialize_encryption_for_column' do
    before { allow(metadata_manager).to receive(:column_encrypted?).and_return(false) }

    it 'generates a data key, stores it, and records the column' do
      expect(utility.initialize_encryption_for_column('users', 'ssn', master_key_arn)).to eq(7)

      expect(key_manager).to have_received(:generate_data_key).with(master_key_arn)
      expect(sql_runner).to have_received(:update)
        .with(connection, /INSERT INTO encrypt\.encryption_metadata /,
              ['users', 'ssn', 'AES-256-GCM', 7, instance_of(Time), instance_of(Time)])
    end

    it 'records the column with the algorithm it was given' do
      utility.initialize_encryption_for_column('users', 'ssn', master_key_arn,
                                               encryption::EncryptionAlgorithm::AES_128_GCM)

      expect(sql_runner).to have_received(:update)
        .with(connection, anything, array_including('AES-128-GCM'))
    end

    it 'names the stored key after the column it belongs to' do
      utility.initialize_encryption_for_column('users', 'ssn', master_key_arn)

      expect(key_manager).to have_received(:store_key_metadata) do |metadata|
        expect(metadata.key_name).to start_with('key-users-ssn-')
        expect(metadata.master_key_arn).to eq(master_key_arn)
        expect(metadata.encrypted_data_key).to eq('AQIDAHj...')
        expect(metadata.hmac_key).to eq('h' * 32)
      end
    end

    # Nothing here encrypts anything, so the plaintext key has no reason to stay in memory.
    it 'wipes the plaintext data key once it is stored' do
      utility.initialize_encryption_for_column('users', 'ssn', master_key_arn)
      expect(plaintext_key).to eq("\0" * 32)
    end

    it 'wipes the plaintext data key even when it could not be stored' do
      allow(key_manager).to receive(:store_key_metadata).and_raise(StandardError, 'duplicate key value')

      expect { utility.initialize_encryption_for_column('users', 'ssn', master_key_arn) }.to raise_error(key_error)
      expect(plaintext_key).to eq("\0" * 32)
    end

    it 'reloads the metadata cache so that the column is encrypted from now on' do
      utility.initialize_encryption_for_column('users', 'ssn', master_key_arn)
      expect(metadata_manager).to have_received(:refresh)
    end

    it 'does not reload a cache that is turned off' do
      utility = described_class.new(key_manager: key_manager, metadata_manager: metadata_manager,
                                    connection_provider: connection_provider, sql_runner: sql_runner,
                                    kms_client: kms_client, config: config.with(metadata_cache_enabled: false))
      utility.initialize_encryption_for_column('users', 'ssn', master_key_arn)

      expect(metadata_manager).not_to have_received(:refresh)
    end

    # Overwriting the configuration would leave every value already written unreadable, since it
    # was encrypted with the key that is being replaced.
    it 'refuses a column that is already encrypted' do
      allow(metadata_manager).to receive(:column_encrypted?).and_return(true)

      expect { utility.initialize_encryption_for_column('users', 'ssn', master_key_arn) }
        .to raise_error(key_error, /Column users\.ssn is already encrypted/) do |error|
          expect(error.context).to include(table: 'users', column: 'ssn')
        end
      expect(key_manager).not_to have_received(:generate_data_key)
    end

    it 'reports being unable to tell whether the column is already encrypted' do
      allow(metadata_manager).to receive(:column_encrypted?)
        .and_raise(metadata_error.lookup_failed('relation does not exist'))

      expect { utility.initialize_encryption_for_column('users', 'ssn', master_key_arn) }
        .to raise_error(key_error, /Failed to check the kms_encryption status of the column/)
      expect(key_manager).not_to have_received(:generate_data_key)
    end
  end

  describe '#generate_and_store_data_key' do
    # The driver-specific upsert grammar now lives in the dialect; the utility only asks for it and
    # appends it to the insert. The ON CONFLICT / ON DUPLICATE KEY syntax is covered by the dialect specs.
    it 'appends the dialect upsert clause from the sql runner to the insert' do
      allow(sql_runner).to receive(:upsert_clause)
        .with(%w[table_name column_name], %w[encryption_algorithm key_id updated_at])
        .and_return('UPSERT_CLAUSE_SENTINEL')
      utility.generate_and_store_data_key('users', 'ssn', master_key_arn)

      expect(sql_runner).to have_received(:update)
        .with(connection, /VALUES \(\?, \?, \?, \?, \?, \?\) UPSERT_CLAUSE_SENTINEL/, any_args)
    end

    it 'needs a table, a column, and a master key' do
      expect { utility.generate_and_store_data_key(nil, 'ssn', master_key_arn) }
        .to raise_error(ArgumentError, /table_name is required/)
      expect { utility.generate_and_store_data_key('users', nil, master_key_arn) }
        .to raise_error(ArgumentError, /column_name is required/)
      expect { utility.generate_and_store_data_key('users', 'ssn', nil) }
        .to raise_error(ArgumentError, /master_key_arn is required/)
    end

    it 'falls back to the default algorithm when none was named' do
      utility.generate_and_store_data_key('users', 'ssn', master_key_arn, '  ')
      expect(sql_runner).to have_received(:update)
        .with(connection, anything, array_including(encryption::EncryptionAlgorithm::DEFAULT))
    end

    it 'refuses an algorithm it cannot encrypt with' do
      expect { utility.generate_and_store_data_key('users', 'ssn', master_key_arn, 'rot13') }
        .to raise_error(AwsRubyDatabaseDriverWrapper::Errors::EncryptionError, /Unsupported kms_encryption algorithm/)
      expect(key_manager).not_to have_received(:generate_data_key)
    end

    it 'reports a failure to write the configuration' do
      allow(sql_runner).to receive(:update).and_raise(StandardError, 'permission denied')

      expect { utility.generate_and_store_data_key('users', 'ssn', master_key_arn) }
        .to raise_error(key_error, /Failed to generate and store the data key: permission denied/) do |error|
          expect(error.context).to include(table: 'users', column: 'ssn')
        end
    end
  end

  describe '#rotate_data_key' do
    let(:key_metadata) do
      encryption::KeyMetadata.new(id: 3, key_id: 'key-uuid', master_key_arn: master_key_arn,
                                  encrypted_data_key: 'AQIDAHj...', hmac_key: 'h' * 32)
    end
    let(:column_config) do
      encryption::ColumnEncryptionConfig.new(table_name: 'users', column_name: 'ssn', key_id: 3,
                                             key_metadata: key_metadata)
    end

    before { allow(metadata_manager).to receive(:column_config).and_return(column_config) }

    # Only new writes use the new key. Values already written stay readable because the row they
    # are in still points at the key they were written with until it is re-encrypted.
    it 'stores a new data key and points the column at it' do
      expect(utility.rotate_data_key('users', 'ssn')).to eq(7)

      expect(sql_runner).to have_received(:update)
        .with(connection, /UPDATE encrypt\.encryption_metadata SET key_id = \?, updated_at = \?/,
              [7, instance_of(Time), 'users', 'ssn'])
    end

    it 'keeps the current master key when no other one was named' do
      utility.rotate_data_key('users', 'ssn')
      expect(key_manager).to have_received(:generate_data_key).with(master_key_arn)
    end

    it 'can rotate onto a different master key' do
      other_arn = 'arn:aws:kms:us-east-1:123456789012:key/efgh'
      utility.rotate_data_key('users', 'ssn', other_arn)

      expect(key_manager).to have_received(:generate_data_key).with(other_arn)
    end

    it 'reloads the metadata cache so that new writes use the new key' do
      utility.rotate_data_key('users', 'ssn')
      expect(metadata_manager).to have_received(:refresh)
    end

    it 'wipes the plaintext data key' do
      utility.rotate_data_key('users', 'ssn')
      expect(plaintext_key).to eq("\0" * 32)
    end

    it 'needs a table and a column' do
      expect { utility.rotate_data_key(nil, 'ssn') }.to raise_error(ArgumentError, /table_name is required/)
      expect { utility.rotate_data_key('users', nil) }.to raise_error(ArgumentError, /column_name is required/)
    end

    it 'refuses a column that is not encrypted' do
      allow(metadata_manager).to receive(:column_config).and_return(nil)

      expect { utility.rotate_data_key('users', 'ssn') }
        .to raise_error(key_error, /No kms_encryption configuration exists for users\.ssn/)
      expect(key_manager).not_to have_received(:generate_data_key)
    end

    # A new key that nothing points at would leave the column encrypted with the old one, so this
    # has to be reported rather than passed over.
    it 'reports a configuration row that was not updated' do
      allow(sql_runner).to receive(:update).and_return(0)

      expect { utility.rotate_data_key('users', 'ssn') }
        .to raise_error(key_error, /No kms_encryption configuration row was updated for users\.ssn/) do |error|
          expect(error.context).to include(table: 'users', column: 'ssn')
        end
    end

    it 'reports a failure to generate the new key' do
      allow(key_manager).to receive(:generate_data_key).and_raise(StandardError, 'KMSInternalException')

      expect { utility.rotate_data_key('users', 'ssn') }
        .to raise_error(key_error, /Failed to rotate the data key: KMSInternalException/)
    end
  end

  describe '#remove_encryption_for_column' do
    # The key stays in key_storage on purpose: values already written are still encrypted with it.
    it 'deletes the configuration row and leaves the key alone' do
      expect(utility.remove_encryption_for_column('users', 'ssn')).to be(true)

      expect(sql_runner).to have_received(:update)
        .with(connection, /DELETE FROM encrypt\.encryption_metadata /, %w[users ssn])
      expect(sql_runner).not_to have_received(:update).with(connection, /key_storage/, any_args)
    end

    it 'is false, with a warning, when the column was not encrypted' do
      allow(sql_runner).to receive(:update).and_return(0)

      expect(utility.remove_encryption_for_column('users', 'ssn')).to be(false)
      expect(AwsRubyDatabaseDriverWrapper.logger).to have_received(:warn)
        .with(/No kms_encryption configuration existed for users\.ssn/)
    end

    it 'reloads the metadata cache so that the column stops being encrypted' do
      utility.remove_encryption_for_column('users', 'ssn')
      expect(metadata_manager).to have_received(:refresh)
    end

    it 'needs a table and a column' do
      expect { utility.remove_encryption_for_column(nil, 'ssn') }.to raise_error(ArgumentError, /table_name/)
      expect { utility.remove_encryption_for_column('users', nil) }.to raise_error(ArgumentError, /column_name/)
    end

    it 'reports a failed delete' do
      allow(sql_runner).to receive(:update).and_raise(StandardError, 'permission denied')

      expect { utility.remove_encryption_for_column('users', 'ssn') }
        .to raise_error(key_error, /Failed to remove the kms_encryption configuration: permission denied/) do |error|
          expect(error.code).to eq(key_error::KEY_STORAGE_FAILED)
          expect(error.context).to include(table: 'users', column: 'ssn')
        end
    end
  end

  describe '#columns_using_key' do
    # Worth seeing before a key is rotated or retired: it can be shared by more than one column.
    it 'lists the columns the key is used by' do
      allow(sql_runner).to receive(:query)
        .and_return([{ 'table_name' => 'users', 'column_name' => 'ssn' },
                     { 'table_name' => 'orders', 'column_name' => 'card_number' }])

      expect(utility.columns_using_key(3)).to eq(['users.ssn', 'orders.card_number'])
      expect(sql_runner).to have_received(:query)
        .with(connection, /FROM encrypt\.encryption_metadata WHERE key_id = \?/, [3])
    end

    it 'is empty for a key no column uses' do
      allow(sql_runner).to receive(:query).and_return([])
      expect(utility.columns_using_key(3)).to eq([])
    end

    it 'needs a key' do
      expect { utility.columns_using_key(nil) }.to raise_error(ArgumentError, /key_id is required/)
    end

    it 'reports a failed query' do
      allow(sql_runner).to receive(:query).and_raise(StandardError, 'relation does not exist')

      expect { utility.columns_using_key(3) }
        .to raise_error(key_error, /Failed to find the columns using the key: relation does not exist/)
    end
  end

  describe '#validate_master_key' do
    it 'asks the key manager' do
      allow(key_manager).to receive(:validate_master_key).with(master_key_arn).and_return(true)
      expect(utility.validate_master_key(master_key_arn)).to be(true)
    end

    it 'needs a master key' do
      expect { utility.validate_master_key(nil) }.to raise_error(ArgumentError, /master_key_arn is required/)
    end
  end
end
