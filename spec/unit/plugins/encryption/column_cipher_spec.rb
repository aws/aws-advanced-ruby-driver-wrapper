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
require 'aws_advanced_ruby_driver_wrapper/plugins/kms_encryption/column_cipher'
require 'aws_advanced_ruby_driver_wrapper/plugins/kms_encryption/column_encryption_config'
require 'aws_advanced_ruby_driver_wrapper/plugins/kms_encryption/key_manager'
require 'aws_advanced_ruby_driver_wrapper/plugins/kms_encryption/sql_runner'

RSpec.describe AwsAdvancedRubyDriverWrapper::Plugins::Encryption::ColumnCipher do
  let(:encryption) { AwsAdvancedRubyDriverWrapper::Plugins::Encryption }
  let(:encryption_error) { AwsAdvancedRubyDriverWrapper::Errors::EncryptionError }
  let(:key_manager) { instance_double(encryption::KeyManager) }
  # A real runner over the mysql2 dialect, so that read_binary behaves as it does in production.
  let(:sql_runner) { encryption::SqlRunner.new(AwsAdvancedRubyDriverWrapper::DriverDialects::MysqlDriverDialect.new) }
  let(:data_key) { +('a' * 32) }
  let(:hmac_key) { 'h' * 32 }
  let(:key_metadata) do
    encryption::KeyMetadata.new(id: 1, key_id: 'key-uuid', master_key_arn: 'arn:aws:kms:us-east-1:1:key/abcd',
                                encrypted_data_key: 'AQIDAHj...', hmac_key: hmac_key)
  end
  let(:config) do
    encryption::ColumnEncryptionConfig.new(table_name: 'users', column_name: 'ssn', key_metadata: key_metadata)
  end
  subject(:cipher) { described_class.new(key_manager: key_manager, sql_runner: sql_runner) }

  before { allow(key_manager).to receive(:decrypt_data_key).and_return(data_key) }

  describe '#encrypt' do
    it 'encrypts with the data key the key manager unwrapped' do
      encrypted = cipher.encrypt('123-45-6789', config)

      expect(key_manager).to have_received(:decrypt_data_key).with('AQIDAHj...', 'arn:aws:kms:us-east-1:1:key/abcd')
      expect(encrypted.bytesize).to be >= encryption::EncryptionService::MIN_ENCRYPTED_LENGTH
    end

    it 'leaves a nil value alone, so a nullable column stays null' do
      expect(cipher.encrypt(nil, config)).to be_nil
      expect(key_manager).not_to have_received(:decrypt_data_key)
    end

    # A cipher lives for one intercepted call, so a statement touching many rows of the same
    # column costs a single KMS Decrypt.
    it 'unwraps the data key once however many values it encrypts' do
      3.times { |i| cipher.encrypt("value-#{i}", config) }
      expect(key_manager).to have_received(:decrypt_data_key).once
    end

    it 'uses the algorithm the column is configured with' do
      short_key = +('k' * 16)
      allow(key_manager).to receive(:decrypt_data_key).and_return(short_key)
      aes128 = config.with(algorithm: encryption::EncryptionAlgorithm::AES_128_GCM)

      expect(cipher.decrypt(cipher.encrypt('123-45-6789', aes128), aes128)).to eq('123-45-6789')
    end
  end

  describe '#decrypt' do
    it 'reads back what it encrypted' do
      expect(cipher.decrypt(cipher.encrypt('123-45-6789', config), config)).to eq('123-45-6789')
    end

    # Both drivers hand back a text column as a string, so the decrypted value is one too.
    it 'returns the value as a string' do
      expect(cipher.decrypt(cipher.encrypt(42, config), config)).to eq('42')
    end

    # A column that was written before kms_encryption was turned on still has to read back.
    it 'leaves a value that is not an encrypted payload untouched' do
      expect(cipher.decrypt('123-45-6789', config)).to eq('123-45-6789')
    end

    it 'leaves a value that is not a string untouched' do
      expect(cipher.decrypt(42, config)).to eq(42)
      expect(cipher.decrypt(nil, config)).to be_nil
    end

    # A value that fails its integrity check cannot be told apart from a value written before
    # kms_encryption was turned on, so it comes back as the bytes that are actually stored rather
    # than as a plaintext the wrapper cannot vouch for.
    it 'never decrypts a payload that fails its integrity check' do
      encrypted = cipher.encrypt('123-45-6789', config)
      encrypted.setbyte(50, encrypted.getbyte(50) ^ 0xff)

      decrypted = cipher.decrypt(encrypted, config)
      expect(decrypted).to be(encrypted)
      expect(decrypted).not_to include('123-45-6789')
    end

    it 'refuses a payload that is signed but was encrypted with a different data key' do
      encrypted = cipher.encrypt('123-45-6789', config)
      cipher.release
      allow(key_manager).to receive(:decrypt_data_key).and_return(+('z' * 32))

      expect { cipher.decrypt(encrypted, config) }
        .to raise_error(encryption_error, /the authentication tag does not match this data key/)
    end

    it 'unwraps the data key once however many values it decrypts' do
      encrypted = cipher.encrypt('123-45-6789', config)
      3.times { cipher.decrypt(encrypted, config) }

      expect(key_manager).to have_received(:decrypt_data_key).once
    end

    # After a key rotation the column's current key differs from the one an existing value was
    # written with. The value's payload names its own key, so the cipher resolves that key from
    # key_storage and still decrypts it, rather than failing against the current key.
    it 'decrypts a value written under a rotated-away key by resolving the key its payload names' do
      encrypted = cipher.encrypt('123-45-6789', config) # written under key id 1

      rotated_key = encryption::KeyMetadata.new(id: 2, key_id: 'new-uuid',
                                                master_key_arn: 'arn:aws:kms:us-east-1:1:key/efgh',
                                                encrypted_data_key: 'BQIDAHj...', hmac_key: 'H' * 32)
      rotated_config = config.with(key_metadata: rotated_key)
      allow(key_manager).to receive(:key_metadata_by_id).with(1).and_return(key_metadata)

      expect(cipher.decrypt(encrypted, rotated_config)).to eq('123-45-6789')
      expect(key_manager).to have_received(:key_metadata_by_id).with(1)
    end

    # A value that is not really an encrypted payload (legacy data, tampered bytes) can still be long
    # enough to carry an embedded key id, which resolves to nothing or errors. A lenient read must
    # return it untouched rather than surfacing the lookup failure.
    it 'returns the value untouched when the key its payload names cannot be looked up' do
      encrypted = cipher.encrypt('123-45-6789', config) # written under key id 1

      rotated_config = config.with(key_metadata: key_metadata.with(id: 2, hmac_key: 'H' * 32))
      allow(key_manager).to receive(:key_metadata_by_id).with(1)
                                                        .and_raise(AwsAdvancedRubyDriverWrapper::Errors::KeyManagementError.key_retrieval_failed('boom'))

      result = nil
      expect { result = cipher.decrypt(encrypted, rotated_config) }.not_to raise_error
      expect(result).to be(encrypted)
    end
  end

  describe '#encrypted_payload?' do
    it 'is true for something long enough to be a payload' do
      expect(cipher.encrypted_payload?(cipher.encrypt('123-45-6789', config))).to be(true)
    end

    it 'is false for a short value' do
      expect(cipher.encrypted_payload?('123-45-6789')).to be(false)
    end

    it 'is false for a value that is not a string' do
      expect(cipher.encrypted_payload?(42)).to be(false)
      expect(cipher.encrypted_payload?(nil)).to be(false)
    end
  end

  describe '#release' do
    it 'zeroes every plaintext data key it unwrapped' do
      cipher.encrypt('123-45-6789', config)
      cipher.release

      expect(data_key).to eq("\0" * 32)
    end

    it 'unwraps the key again after a release' do
      cipher.encrypt('123-45-6789', config)
      cipher.release
      cipher.encrypt('123-45-6789', config)

      expect(key_manager).to have_received(:decrypt_data_key).twice
    end

    it 'can be called when nothing was unwrapped, and twice over' do
      expect { cipher.release }.not_to raise_error
      cipher.encrypt('123-45-6789', config)
      cipher.release
      expect { cipher.release }.not_to raise_error
    end
  end

  describe 'a column with unusable key material' do
    it 'refuses to encrypt without any key material' do
      expect { cipher.encrypt('123-45-6789', config.with(key_metadata: nil)) }
        .to raise_error(encryption_error, /The column has no key material/) do |error|
          expect(error.code).to eq(encryption_error::INVALID_KEY)
          expect(error.context).to eq({ table: 'users', column: 'ssn' })
        end
    end

    # Without the HMAC key an encrypted value could not be told apart from plaintext, nor
    # verified, so writing one would be worse than refusing.
    it 'refuses to encrypt without an HMAC key' do
      expect { cipher.encrypt('123-45-6789', config.with(key_metadata: key_metadata.with(hmac_key: nil))) }
        .to raise_error(encryption_error, /The stored key has no HMAC key/) do |error|
          expect(error.context).to eq({ table: 'users', column: 'ssn' })
        end

      expect { cipher.encrypt('123-45-6789', config.with(key_metadata: key_metadata.with(hmac_key: ''))) }
        .to raise_error(encryption_error, /The stored key has no HMAC key/)
    end

    it 'refuses to decrypt without any key material' do
      expect { cipher.decrypt('some-value', config.with(key_metadata: nil)) }
        .to raise_error(encryption_error, /The column has no key material/)
    end
  end
end
