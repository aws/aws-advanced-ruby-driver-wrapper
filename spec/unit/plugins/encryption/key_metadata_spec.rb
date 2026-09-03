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
require 'aws_advanced_ruby_driver_wrapper/plugins/kms_encryption/key_metadata'

RSpec.describe AwsAdvancedRubyDriverWrapper::Plugins::Encryption::KeyMetadata do
  subject(:metadata) do
    described_class.new(
      id: 1,
      key_id: '1234abcd-12ab-34cd-56ef-1234567890ab',
      key_name: 'users.ssn',
      master_key_arn: 'arn:aws:kms:us-east-1:123456789012:key/1234abcd-56ef',
      encrypted_data_key: 'AQIDAHj...',
      hmac_key: 'h' * 32,
      created_at: Time.at(1_754_899_200)
    )
  end

  describe 'defaults' do
    it 'needs nothing to be built' do
      expect(described_class.new.id).to be_nil
    end

    it 'assumes a 256 bit data key' do
      expect(described_class.new.key_spec).to eq('AES_256')
      expect(described_class::DEFAULT_KEY_SPEC).to eq('AES_256')
    end
  end

  describe '#valid?' do
    it 'is true once the key names a master key and carries an encrypted data key' do
      expect(metadata.valid?).to be(true)
    end

    it 'is false without a master key ARN' do
      expect(metadata.with(master_key_arn: nil).valid?).to be(false)
      expect(metadata.with(master_key_arn: '  ').valid?).to be(false)
    end

    it 'is false without an encrypted data key' do
      expect(metadata.with(encrypted_data_key: nil).valid?).to be(false)
      expect(metadata.with(encrypted_data_key: '').valid?).to be(false)
    end

    it 'is false without a key spec' do
      expect(metadata.with(key_spec: nil).valid?).to be(false)
      expect(metadata.with(key_spec: '  ').valid?).to be(false)
    end
  end

  describe '#with_updated_last_used' do
    it 'stamps a copy without touching the original' do
      now = Time.at(1_754_899_999)
      updated = metadata.with_updated_last_used(now)
      expect(updated.last_used_at).to eq(now)
      expect(metadata.last_used_at).to be_nil
    end

    it 'keeps the rest of the key material' do
      expect(metadata.with_updated_last_used(Time.at(0)).encrypted_data_key).to eq('AQIDAHj...')
    end

    it 'defaults to now' do
      expect(metadata.with_updated_last_used.last_used_at).to be_within(5).of(Time.now)
    end
  end

  # The metadata gets logged and appears in error messages, so it must never render the key
  # material or the account that owns the master key.
  describe '#to_s' do
    it 'redacts the encrypted data key and the HMAC key' do
      expect(metadata.to_s).to include("encrypted_data_key='[REDACTED]'", "hmac_key='[REDACTED]'")
      expect(metadata.to_s).not_to include('AQIDAHj', 'h' * 32)
    end

    it 'masks the account and region of the master key ARN' do
      expect(metadata.to_s).to include('arn:aws:kms:***:***:key/1234***56ef')
      expect(metadata.to_s).not_to include('123456789012')
    end

    it 'shows a missing HMAC key as missing rather than as redacted' do
      expect(metadata.with(hmac_key: nil).to_s).to include('hmac_key=nil')
    end

    it 'keeps the details that identify the row' do
      expect(metadata.to_s).to include('id=1', 'key_id="1234abcd-12ab-34cd-56ef-1234567890ab"', 'key_name="users.ssn"')
    end

    it 'redacts through inspect as well, so an accidental p call is safe' do
      expect(metadata.inspect).to eq(metadata.to_s)
    end
  end
end
