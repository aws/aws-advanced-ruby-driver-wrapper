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
require 'aws_ruby_database_driver_wrapper/plugins/encryption/column_encryption_config'

RSpec.describe AwsRubyDatabaseDriverWrapper::Plugins::Encryption::ColumnEncryptionConfig do
  let(:key_metadata_class) { AwsRubyDatabaseDriverWrapper::Plugins::Encryption::KeyMetadata }
  let(:key_metadata) do
    key_metadata_class.new(master_key_arn: 'arn:aws:kms:us-east-1:123456789012:key/abcd',
                           encrypted_data_key: 'AQIDAHj...', hmac_key: 'h' * 32)
  end

  subject(:config) do
    described_class.new(table_name: 'users', column_name: 'ssn', key_id: 7, key_metadata: key_metadata)
  end

  it 'defaults to the default algorithm' do
    expect(config.algorithm).to eq(AwsRubyDatabaseDriverWrapper::Plugins::Encryption::EncryptionAlgorithm::DEFAULT)
  end

  it 'needs only a table and a column' do
    expect(described_class.new(table_name: 'users', column_name: 'ssn').key_metadata).to be_nil
  end

  describe '#column_identifier' do
    it 'is the cache key for the column' do
      expect(config.column_identifier).to eq('users.ssn')
    end
  end

  describe '#usable?' do
    it 'is true with a supported algorithm and valid key material' do
      expect(config.usable?).to be(true)
    end

    it 'is false without any key material' do
      expect(config.with(key_metadata: nil).usable?).to be(false)
    end

    it 'is false when the key material is incomplete' do
      expect(config.with(key_metadata: key_metadata.with(encrypted_data_key: nil)).usable?).to be(false)
    end

    # A row written by a newer wrapper version could name an algorithm this one cannot use.
    it 'is false for an algorithm this wrapper does not support' do
      expect(config.with(algorithm: 'AES-512-GCM').usable?).to be(false)
      expect(config.with(algorithm: nil).usable?).to be(false)
    end
  end
end
