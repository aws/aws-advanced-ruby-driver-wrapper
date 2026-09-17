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
require 'aws_advanced_ruby_driver_wrapper/plugins/kms_encryption/data_key_cache'
require 'aws_advanced_ruby_driver_wrapper/plugins/kms_encryption/encryption_config'
require 'aws_advanced_ruby_driver_wrapper/plugins/kms_encryption/key_manager'
require 'aws_advanced_ruby_driver_wrapper/plugins/kms_encryption/sql_runner'

RSpec.describe AwsAdvancedRubyDriverWrapper::Plugins::Encryption::KeyManager do
  let(:encryption) { AwsAdvancedRubyDriverWrapper::Plugins::Encryption }
  let(:key_error) { AwsAdvancedRubyDriverWrapper::Errors::KeyManagementError }
  let(:kms_client) { instance_double(Aws::KMS::Client) }
  let(:connection) { double('Connection') }
  let(:sql_runner) { instance_double(encryption::SqlRunner) }
  let(:audit_logger) { encryption::AuditLogger.new(false) }
  let(:data_key_cache) { encryption::DataKeyCache.new(max_size: 10, ttl_sec: 60) }
  # A 1 ms backoff base keeps the retry examples from actually waiting.
  let(:config) do
    build_encryption_config(key_management_max_retries: 2, key_management_retry_backoff_base_sec: 0.001)
  end
  # The KMS SDK names its error classes after the KMS error code and attaches the request
  # context, including the HTTP response, to every error it raises.
  StubHttpResponse = Struct.new(:status_code)
  StubRequestContext = Struct.new(:http_response)

  let(:plaintext_key) { 'a' * 32 }
  let(:ciphertext_blob) { 'wrapped-key-bytes' }
  let(:encrypted_data_key) { Base64.strict_encode64(ciphertext_blob) }
  subject(:manager) do
    described_class.new(kms_client: kms_client, connection: connection, sql_runner: sql_runner,
                        config: config, data_key_cache: data_key_cache, audit_logger: audit_logger)
  end

  after { data_key_cache.shutdown }

  # The connection the manager runs its metadata statements on (yielded by its supplied connection).
  def stubbed_connection
    connection
  end

  describe '#decrypt_data_key' do
    before { allow(kms_client).to receive(:decrypt).and_return(double('DecryptResponse', plaintext: plaintext_key)) }

    it 'asks KMS to unwrap the stored key' do
      expect(manager.decrypt_data_key(encrypted_data_key)).to eq(plaintext_key)
      expect(kms_client).to have_received(:decrypt).with(ciphertext_blob: ciphertext_blob)
    end

    it 'names the master key so that KMS checks the key the data was wrapped with' do
      manager.decrypt_data_key(encrypted_data_key, 'arn:aws:kms:us-east-1:1:key/abcd')
      expect(kms_client).to have_received(:decrypt)
        .with(ciphertext_blob: ciphertext_blob, key_id: 'arn:aws:kms:us-east-1:1:key/abcd')
    end

    it 'returns a copy the caller can wipe without touching the SDK response' do
      response_plaintext = +('a' * 32)
      allow(kms_client).to receive(:decrypt).and_return(double('DecryptResponse', plaintext: response_plaintext))

      manager.decrypt_data_key(encrypted_data_key).replace("\0" * 32)
      expect(response_plaintext).to eq('a' * 32)
    end

    it 'accepts a base64 key that was stored with line breaks' do
      wrapped = Base64.strict_encode64(ciphertext_blob).scan(/.{1,4}/).join("\n")
      expect(manager.decrypt_data_key(wrapped)).to eq(plaintext_key)
    end

    # A KMS Decrypt per row would be both slow and expensive, so the plaintext key is cached.
    it 'calls KMS once for a key it has already unwrapped' do
      3.times { manager.decrypt_data_key(encrypted_data_key) }
      expect(kms_client).to have_received(:decrypt).once
    end

    it 'calls KMS again for a different stored key' do
      manager.decrypt_data_key(encrypted_data_key)
      manager.decrypt_data_key(Base64.strict_encode64('another-wrapped-key'))

      expect(kms_client).to have_received(:decrypt).twice
    end

    it 'refuses a key metadata row with no encrypted data key' do
      [nil, '', '   '].each do |empty|
        expect { manager.decrypt_data_key(empty, 'arn:aws:kms:us-east-1:123456789012:key/abcd') }
          .to raise_error(key_error, /The stored key metadata has no encrypted data key/) do |error|
            expect(error.code).to eq(key_error::INVALID_KEY_METADATA)
            expect(error.context[:master_key_arn]).to eq('arn:aws:kms:***:***:key/***')
          end
      end

      expect(kms_client).not_to have_received(:decrypt)
    end

    it 'reports a KMS refusal as a key management error' do
      allow(kms_client).to receive(:decrypt).and_raise(StandardError, 'AccessDeniedException')

      expect { manager.decrypt_data_key(encrypted_data_key) }
        .to raise_error(key_error, /DECRYPT_DATA_KEY failed: AccessDeniedException/) do |error|
          expect(error.context[:operation]).to eq('DECRYPT_DATA_KEY')
        end
    end
  end

  describe '#generate_data_key' do
    let(:response) { double('GenerateDataKeyResponse', plaintext: plaintext_key, ciphertext_blob: ciphertext_blob) }

    before { allow(kms_client).to receive(:generate_data_key).and_return(response) }

    it 'asks KMS for a 256 bit data key wrapped with the master key' do
      manager.generate_data_key('arn:aws:kms:us-east-1:1:key/abcd')
      expect(kms_client).to have_received(:generate_data_key)
        .with(key_id: 'arn:aws:kms:us-east-1:1:key/abcd', key_spec: 'AES_256')
    end

    it 'returns the plaintext key along with the form that gets stored' do
      generated = manager.generate_data_key('arn:aws:kms:us-east-1:1:key/abcd')

      expect(generated.plaintext).to eq(plaintext_key)
      expect(generated.encrypted_data_key).to eq(encrypted_data_key)
    end

    # The HMAC key never goes to KMS: it is generated here and stored beside the data key.
    it 'generates a fresh 256 bit HMAC key of its own' do
      first = manager.generate_data_key('arn:aws:kms:us-east-1:1:key/abcd')
      second = manager.generate_data_key('arn:aws:kms:us-east-1:1:key/abcd')

      expect(first.hmac_key.bytesize).to eq(described_class::HMAC_KEY_LENGTH)
      expect(first.hmac_key).not_to eq(second.hmac_key)
    end

    it 'reports a KMS refusal as a key management error' do
      allow(kms_client).to receive(:generate_data_key).and_raise(StandardError, 'NotFoundException')

      expect { manager.generate_data_key('arn:aws:kms:us-east-1:1:key/abcd') }
        .to raise_error(key_error, /GENERATE_DATA_KEY failed: NotFoundException/)
    end
  end

  describe '#create_master_key' do
    it 'creates a symmetric encrypt and decrypt key and returns its ARN' do
      arn = 'arn:aws:kms:us-east-1:1:key/abcd'
      allow(kms_client).to receive(:create_key)
        .and_return(double('CreateKeyResponse', key_metadata: double('KeyMetadata', arn: arn)))

      expect(manager.create_master_key('ruby wrapper key')).to eq(arn)
      expect(kms_client).to have_received(:create_key)
        .with(description: 'ruby wrapper key', key_usage: 'ENCRYPT_DECRYPT', key_spec: 'SYMMETRIC_DEFAULT')
    end

    it 'reports a KMS refusal as a key management error' do
      allow(kms_client).to receive(:create_key).and_raise(StandardError, 'LimitExceeded')

      expect { manager.create_master_key('ruby wrapper key') }
        .to raise_error(key_error, /CREATE_MASTER_KEY failed: LimitExceeded/)
    end
  end

  describe '#validate_master_key' do
    def describe_key(enabled:, key_state: 'Enabled', key_usage: 'ENCRYPT_DECRYPT')
      allow(kms_client).to receive(:describe_key).and_return(
        double('DescribeKeyResponse',
               key_metadata: double('KeyMetadata', enabled: enabled, key_state: key_state, key_usage: key_usage))
      )
    end

    it 'accepts a key that is enabled and can encrypt and decrypt' do
      describe_key(enabled: true)
      expect(manager.validate_master_key('arn:aws:kms:us-east-1:1:key/abcd')).to be(true)
    end

    it 'rejects a disabled key' do
      describe_key(enabled: false)
      expect(manager.validate_master_key('arn:aws:kms:us-east-1:1:key/abcd')).to be(false)
    end

    # A key that is scheduled for deletion still describes, but must not be used.
    it 'rejects a key that is not in the enabled state' do
      describe_key(enabled: true, key_state: 'PendingDeletion')
      expect(manager.validate_master_key('arn:aws:kms:us-east-1:1:key/abcd')).to be(false)
    end

    it 'rejects a signing key' do
      describe_key(enabled: true, key_usage: 'SIGN_VERIFY')
      expect(manager.validate_master_key('arn:aws:kms:us-east-1:1:key/abcd')).to be(false)
    end

    # Validation is a pre-flight check, so a KMS failure is a false rather than a raise.
    it 'rejects a key it could not describe' do
      allow(kms_client).to receive(:describe_key).and_raise(StandardError, 'AccessDeniedException')
      expect(manager).to receive(:logger).and_return(AwsAdvancedRubyDriverWrapper.logger)
      expect(AwsAdvancedRubyDriverWrapper.logger).to receive(:warn).with(/Master key validation failed/)

      expect(manager.validate_master_key('arn:aws:kms:us-east-1:1:key/abcd')).to be(false)
    end
  end

  describe 'retrying a KMS call' do
    it 'retries a throttled request and returns the eventual result' do
      responses = [throttling_error, throttling_error, double('DecryptResponse', plaintext: plaintext_key)]
      allow(kms_client).to receive(:decrypt) do
        response = responses.shift
        raise response if response.is_a?(StandardError)

        response
      end

      expect(manager.decrypt_data_key(encrypted_data_key)).to eq(plaintext_key)
      expect(kms_client).to have_received(:decrypt).exactly(3).times
    end

    it 'gives up after the configured number of retries' do
      allow(kms_client).to receive(:decrypt).and_raise(throttling_error)

      expect { manager.decrypt_data_key(encrypted_data_key) }
        .to raise_error(key_error, /ThrottlingException/) do |error|
          expect(error.context[:retry_attempt]).to eq('3/3')
        end
      expect(kms_client).to have_received(:decrypt).exactly(3).times
    end

    it 'retries a request that failed with a server error' do
      allow(kms_client).to receive(:decrypt).and_raise(http_status_error(503))
      expect { manager.decrypt_data_key(encrypted_data_key) }.to raise_error(key_error)
      expect(kms_client).to have_received(:decrypt).exactly(3).times
    end

    it 'retries a request that was rate limited' do
      allow(kms_client).to receive(:decrypt).and_raise(http_status_error(429))
      expect { manager.decrypt_data_key(encrypted_data_key) }.to raise_error(key_error)
      expect(kms_client).to have_received(:decrypt).exactly(3).times
    end

    it 'retries a networking failure, and says the connection was the problem' do
      allow(kms_client).to receive(:decrypt).and_raise(Errno::ECONNREFUSED)

      expect { manager.decrypt_data_key(encrypted_data_key) }
        .to raise_error(key_error) { |error| expect(error.code).to eq(key_error::KMS_CONNECTION_FAILED) }
      expect(kms_client).to have_received(:decrypt).exactly(3).times
    end

    # Retrying a rejected request would only be rejected again.
    it 'does not retry a request KMS refused outright' do
      allow(kms_client).to receive(:decrypt).and_raise(http_status_error(400))

      expect { manager.decrypt_data_key(encrypted_data_key) }
        .to raise_error(key_error) { |error| expect(error.context[:retry_attempt]).to eq('1/3') }
      expect(kms_client).to have_received(:decrypt).once
    end

    it 'does not retry when retries are turned off' do
      allow(kms_client).to receive(:decrypt).and_raise(throttling_error)
      manager = described_class.new(kms_client: kms_client, connection: connection,
                                    sql_runner: sql_runner, config: config.with(key_management_max_retries: 0),
                                    data_key_cache: data_key_cache)

      expect { manager.decrypt_data_key(encrypted_data_key) }.to raise_error(key_error)
      expect(kms_client).to have_received(:decrypt).once
    end
  end

  describe 'the key_storage table' do
    let(:key_metadata) do
      encryption::KeyMetadata.new(key_name: 'users.ssn', master_key_arn: 'arn:aws:kms:us-east-1:1:key/abcd',
                                  encrypted_data_key: encrypted_data_key, hmac_key: 'h' * 32)
    end

    describe '#store_key_metadata' do
      it 'inserts the key and returns it with its generated id' do
        connection = stubbed_connection
        allow(sql_runner).to receive(:binary_param) { |value| value }
        allow(sql_runner).to receive(:insert_returning_id).and_return(7)

        stored = manager.store_key_metadata(key_metadata)

        expect(stored.id).to eq(7)
        expect(sql_runner).to have_received(:insert_returning_id)
          .with(connection, /INSERT INTO encrypt\.key_storage /, array_including('arn:aws:kms:us-east-1:1:key/abcd'))
      end

      it 'gives the key an identifier and timestamps of its own' do
        stubbed_connection
        allow(sql_runner).to receive(:binary_param) { |value| value }
        allow(sql_runner).to receive(:insert_returning_id).and_return(7)

        stored = manager.store_key_metadata(key_metadata)

        expect(stored.key_id).to match(/\A[0-9a-f-]{36}\z/)
        expect(stored.created_at).to be_a(Time)
        expect(stored.last_used_at).to be_a(Time)
      end

      it 'keeps an identifier the caller already chose' do
        stubbed_connection
        allow(sql_runner).to receive(:binary_param) { |value| value }
        allow(sql_runner).to receive(:insert_returning_id).and_return(7)

        expect(manager.store_key_metadata(key_metadata.with(key_id: 'chosen-id')).key_id).to eq('chosen-id')
      end

      # The HMAC key is raw bytes, so it has to be bound as a binary parameter rather than text.
      it 'binds the HMAC key as binary' do
        stubbed_connection
        allow(sql_runner).to receive(:binary_param).and_return('bound-bytes')
        allow(sql_runner).to receive(:insert_returning_id).and_return(7)

        manager.store_key_metadata(key_metadata)

        expect(sql_runner).to have_received(:binary_param).with('h' * 32)
        expect(sql_runner).to have_received(:insert_returning_id)
          .with(anything, anything, array_including('bound-bytes'))
      end

      it 'reports a failed insert as a key management error' do
        stubbed_connection
        allow(sql_runner).to receive(:binary_param) { |value| value }
        allow(sql_runner).to receive(:insert_returning_id).and_raise(StandardError, 'duplicate key value')

        expect { manager.store_key_metadata(key_metadata.with(key_id: '1234abcd-12ab-34cd-56ef-7890abcdef12')) }
          .to raise_error(key_error, /Failed to store key metadata: duplicate key value/) do |error|
            expect(error.code).to eq(key_error::KEY_STORAGE_FAILED)
            expect(error.context[:key_id]).to eq('1234***ef12')
          end
      end

      # Storing metadata that names no master key or carries no encrypted data key would leave a
      # key_storage row that can never encrypt or decrypt anything, so it is refused before the insert.
      it 'refuses metadata that is not valid without touching the database' do
        allow(sql_runner).to receive(:insert_returning_id)

        expect { manager.store_key_metadata(key_metadata.with(master_key_arn: '')) }
          .to raise_error(key_error) { |error| expect(error.code).to eq(key_error::INVALID_KEY_METADATA) }
        expect { manager.store_key_metadata(key_metadata.with(encrypted_data_key: '')) }
          .to raise_error(key_error) { |error| expect(error.code).to eq(key_error::INVALID_KEY_METADATA) }
        expect(sql_runner).not_to have_received(:insert_returning_id)
      end
    end

    describe '#key_metadata_by_id' do
      let(:row) do
        { 'id' => '7', 'key_id' => 'key-uuid', 'name' => 'users.ssn',
          'master_key_arn' => 'arn:aws:kms:us-east-1:1:key/abcd', 'encrypted_data_key' => encrypted_data_key,
          'hmac_key' => 'raw-bytes', 'key_spec' => 'AES_256',
          'created_at' => '2026-01-02 03:04:05 UTC', 'last_used_at' => '2026-01-02 03:04:05 UTC' }
      end

      it 'reads the row and builds the key metadata' do
        connection = stubbed_connection
        allow(sql_runner).to receive(:query).and_return([row])
        allow(sql_runner).to receive(:read_binary).with('raw-bytes').and_return('h' * 32)

        metadata = manager.key_metadata_by_id(7)

        expect(sql_runner).to have_received(:query).with(connection, /FROM encrypt\.key_storage WHERE id = \?/, [7])
        expect(metadata.id).to eq(7)
        expect(metadata.key_id).to eq('key-uuid')
        expect(metadata.key_name).to eq('users.ssn')
        expect(metadata.hmac_key).to eq('h' * 32)
        expect(metadata.created_at).to eq(Time.utc(2026, 1, 2, 3, 4, 5))
      end

      it 'is nil when no such key is stored' do
        stubbed_connection
        allow(sql_runner).to receive(:query).and_return([])

        expect(manager.key_metadata_by_id(7)).to be_nil
      end

      it 'reports a failed read as a key management error' do
        stubbed_connection
        allow(sql_runner).to receive(:query).and_raise(StandardError, 'relation does not exist')

        expect { manager.key_metadata_by_id(7) }
          .to raise_error(key_error, /Failed to read key metadata: relation does not exist/) do |error|
            expect(error.code).to eq(key_error::KEY_RETRIEVAL_FAILED)
          end
      end
    end

    describe '#touch_key' do
      it 'stamps the key as used' do
        connection = stubbed_connection
        allow(sql_runner).to receive(:execute)

        manager.touch_key('key-uuid')

        expect(sql_runner).to have_received(:execute)
          .with(connection, /UPDATE encrypt\.key_storage SET last_used_at = \?/, [instance_of(Time), 'key-uuid'])
      end

      # The stamp is bookkeeping: losing it must not fail the query the application asked for.
      it 'swallows a failed update' do
        stubbed_connection
        allow(sql_runner).to receive(:execute).and_raise(StandardError, 'deadlock detected')

        expect(manager.touch_key('key-uuid')).to be_nil
      end
    end

    describe '#to_key_metadata' do
      it 'falls back to the default key spec when the column is null' do
        allow(sql_runner).to receive(:read_binary).and_return(nil)
        metadata = manager.to_key_metadata({ 'key_id' => 'key-uuid', 'key_spec' => nil })

        expect(metadata.key_spec).to eq(encryption::KeyMetadata::DEFAULT_KEY_SPEC)
        expect(metadata.created_at).to be_nil
      end

      it 'keeps a timestamp the driver already converted' do
        allow(sql_runner).to receive(:read_binary).and_return(nil)
        created_at = Time.utc(2026, 1, 2, 3, 4, 5)

        expect(manager.to_key_metadata({ 'created_at' => created_at }).created_at).to eq(created_at)
      end
    end
  end

  describe '#data_key_cache_key' do
    # The encrypted data key is hashed so that it cannot leak through a cache key in a log line.
    it 'hashes the encrypted data key' do
      cache_key = manager.data_key_cache_key(encrypted_data_key)

      expect(cache_key).to start_with(described_class::DATA_KEY_CACHE_PREFIX)
      expect(cache_key).not_to include(encrypted_data_key)
    end

    it 'is the same for the same key and different for another' do
      expect(manager.data_key_cache_key(encrypted_data_key)).to eq(manager.data_key_cache_key(encrypted_data_key))
      expect(manager.data_key_cache_key(encrypted_data_key)).not_to eq(manager.data_key_cache_key('other'))
    end
  end

  describe '#generate_key_id' do
    it 'is a fresh identifier every time' do
      expect(manager.generate_key_id).to match(/\A[0-9a-f-]{36}\z/)
      expect(manager.generate_key_id).not_to eq(manager.generate_key_id)
    end
  end

  def throttling_error
    Class.new(StandardError) do
      def self.name
        'Aws::KMS::Errors::ThrottlingException'
      end

      def message
        'ThrottlingException: rate exceeded'
      end

      def context
        StubRequestContext.new(nil)
      end
    end.new
  end

  def http_status_error(status_code, error_code = 'ValidationException')
    Class.new(StandardError) do
      define_method(:context) { StubRequestContext.new(StubHttpResponse.new(status_code)) }
      define_singleton_method(:name) { "Aws::KMS::Errors::#{error_code}" }
    end.new("request failed with status #{status_code}")
  end
end
