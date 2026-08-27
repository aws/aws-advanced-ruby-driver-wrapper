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
require 'aws_advanced_ruby_driver_wrapper/plugins/kms_encryption/encryption_algorithm'

RSpec.describe AwsAdvancedRubyDriverWrapper::Plugins::Encryption::EncryptionAlgorithm do
  subject(:algorithm) { described_class }

  # These names are stored in encryption_metadata.encryption_algorithm and are shared with the
  # other AWS Advanced Wrappers.
  describe 'the algorithm names' do
    it 'spells the names with hyphens' do
      expect(described_class::AES_256_GCM).to eq('AES-256-GCM')
      expect(described_class::AES_128_GCM).to eq('AES-128-GCM')
    end

    it 'defaults to AES-256-GCM' do
      expect(described_class::DEFAULT).to eq(described_class::AES_256_GCM)
    end

    it 'lists every supported algorithm' do
      expect(described_class::ALL).to eq(%w[AES-256-GCM AES-128-GCM])
    end
  end

  describe '.key_length' do
    it 'returns the data key length in bytes' do
      expect(algorithm.key_length('AES-256-GCM')).to eq(32)
      expect(algorithm.key_length('AES-128-GCM')).to eq(16)
    end

    it 'raises for an unsupported algorithm' do
      expect { algorithm.key_length('AES_256_GCM') }.to raise_error(
        AwsAdvancedRubyDriverWrapper::Errors::EncryptionError, /Unsupported kms_encryption algorithm: "AES_256_GCM"/
      )
    end
  end

  describe '.cipher_name' do
    it 'returns the OpenSSL cipher name' do
      expect(algorithm.cipher_name('AES-256-GCM')).to eq('aes-256-gcm')
      expect(algorithm.cipher_name('AES-128-GCM')).to eq('aes-128-gcm')
    end

    it 'raises for an unsupported algorithm' do
      expect { algorithm.cipher_name('rot13') }.to raise_error(
        AwsAdvancedRubyDriverWrapper::Errors::EncryptionError, /Unsupported kms_encryption algorithm/
      )
    end
  end

  describe '.supported?' do
    it 'is true for a supported algorithm' do
      expect(algorithm.supported?('AES-128-GCM')).to be(true)
    end

    it 'is false for anything else' do
      expect(algorithm.supported?('AES-512-GCM')).to be(false)
      expect(algorithm.supported?(nil)).to be(false)
      expect(algorithm.supported?('')).to be(false)
    end
  end

  describe '.unsupported' do
    subject(:error) { algorithm.unsupported('rot13') }

    it 'builds an invalid algorithm error' do
      expect(error.code).to eq(AwsAdvancedRubyDriverWrapper::Errors::EncryptionError::INVALID_ALGORITHM)
    end

    it 'names the supported algorithms' do
      expect(error.base_message).to include('AES-256-GCM', 'AES-128-GCM')
    end

    it 'records the rejected algorithm in its context' do
      expect(error.context[:algorithm]).to eq('rot13')
    end
  end
end
