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
require 'aws_advanced_ruby_driver_wrapper/plugins/kms_encryption/sanitizer'

RSpec.describe AwsAdvancedRubyDriverWrapper::Plugins::Encryption::Sanitizer do
  subject(:sanitizer) { described_class }

  describe '.arn' do
    it 'keeps only the key id' do
      expect(sanitizer.arn('arn:aws:kms:us-east-1:123456789012:key/1234abcd-12ab-34cd-56ef-1234567890ab'))
        .to eq('arn:aws:kms:***:***:key/1234abcd-12ab-34cd-56ef-1234567890ab')
    end

    it 'masks everything when there is no key id to keep' do
      expect(sanitizer.arn('not-an-arn')).to eq('arn:aws:kms:***:***:key/***')
      expect(sanitizer.arn('/leading')).to eq('arn:aws:kms:***:***:key/***')
      expect(sanitizer.arn('arn:aws:kms:us-east-1:123456789012:key/')).to eq('arn:aws:kms:***:***:key/***')
    end

    it 'returns nil for nil' do
      expect(sanitizer.arn(nil)).to be_nil
    end
  end

  describe '.key_id' do
    it 'keeps the first and last four characters' do
      expect(sanitizer.key_id('1234abcd-12ab-34cd')).to eq('1234***34cd')
    end

    it 'masks a short id entirely' do
      expect(sanitizer.key_id('12345678')).to eq('***')
      expect(sanitizer.key_id(42)).to eq('***')
    end

    it 'returns nil for nil' do
      expect(sanitizer.key_id(nil)).to be_nil
    end
  end

  describe '.table_name and .column_name' do
    it 'pass short names through' do
      expect(sanitizer.table_name('users')).to eq('users')
      expect(sanitizer.column_name('ssn')).to eq('ssn')
    end

    it 'truncate long names' do
      truncated = sanitizer.table_name('t' * 60)
      expect(truncated).to end_with('...')
      expect(truncated.length).to eq(described_class::MAX_NAME_LENGTH)
    end

    it 'return nil for nil' do
      expect(sanitizer.table_name(nil)).to be_nil
      expect(sanitizer.column_name(nil)).to be_nil
    end
  end

  describe '.description' do
    it 'masks assignments that look like credentials' do
      expect(sanitizer.description('connect with password=hunter2 now')).to eq('connect with password=*** now')
      expect(sanitizer.description('token=abc123')).to eq('token=***')
    end

    it 'truncates to the description limit' do
      expect(sanitizer.description('d' * 200).length).to eq(described_class::MAX_DESCRIPTION_LENGTH)
    end

    it 'returns nil for nil' do
      expect(sanitizer.description(nil)).to be_nil
    end
  end

  describe '.error_message' do
    it 'masks credentials and KMS ARNs' do
      message = 'Decrypt failed for arn:aws:kms:us-east-1:123456789012:key/1234abcd with secret=shh'
      expect(sanitizer.error_message(message))
        .to eq('Decrypt failed for arn:aws:kms:***:***:key/*** with secret=***')
    end

    it 'truncates to the error message limit' do
      expect(sanitizer.error_message('e' * 400).length).to eq(described_class::MAX_ERROR_MESSAGE_LENGTH)
    end

    it 'returns nil for nil' do
      expect(sanitizer.error_message(nil)).to be_nil
    end
  end

  describe '.config_details' do
    # Rendered hashes end a value at the comma or the closing brace rather than at a space.
    it 'masks credentials inside a rendered hash' do
      expect(sanitizer.config_details('{user=jo, password=hunter2, host=db}'))
        .to eq('{user=jo, password=***, host=db}')
    end

    it 'masks a credential assignment' do
      expect(sanitizer.config_details('credential=abc')).to eq('credential=***')
    end

    # A KMS ARN carries the account id and region, so it is masked in config details just as it is in
    # error messages.
    it 'masks the account and region of a KMS ARN' do
      expect(sanitizer.config_details('master_key_arn=arn:aws:kms:us-east-1:123456789012:key/abcd-1234'))
        .to eq('master_key_arn=arn:aws:kms:***:***:key/***')
    end

    it 'returns nil for nil' do
      expect(sanitizer.config_details(nil)).to be_nil
    end
  end

  describe '.connection_url' do
    it 'masks a password query parameter' do
      expect(sanitizer.connection_url('postgres://db.example.com/app?password=hunter2'))
        .to eq('postgres://db.example.com/app?password=***')
    end

    it 'masks a pwd query parameter' do
      expect(sanitizer.connection_url('mysql://db.example.com/app?pwd=hunter2'))
        .to eq('mysql://db.example.com/app?pwd=***')
    end

    it 'masks credentials embedded in the authority' do
      expect(sanitizer.connection_url('postgres://jo:hunter2@db.example.com/app'))
        .to eq('postgres://***:***@db.example.com/app')
    end

    it 'leaves a URL without credentials alone' do
      expect(sanitizer.connection_url('postgres://db.example.com:5432/app'))
        .to eq('postgres://db.example.com:5432/app')
    end

    it 'returns nil for nil' do
      expect(sanitizer.connection_url(nil)).to be_nil
    end
  end

  describe '.sql' do
    it 'replaces string and numeric literals' do
      expect(sanitizer.sql("SELECT * FROM users WHERE ssn = '123-45-6789' AND id = 42"))
        .to eq("SELECT * FROM users WHERE ssn = '***' AND id = ***")
    end

    it 'keeps the statement shape' do
      expect(sanitizer.sql('INSERT INTO users (name, ssn) VALUES (?, ?)'))
        .to eq('INSERT INTO users (name, ssn) VALUES (?, ?)')
    end

    it 'truncates to the SQL limit' do
      expect(sanitizer.sql("SELECT #{'c' * 200} FROM users").length).to eq(described_class::MAX_SQL_LENGTH)
    end

    it 'returns nil for nil' do
      expect(sanitizer.sql(nil)).to be_nil
    end
  end

  describe '.truncate' do
    it 'leaves a value at the limit alone' do
      expect(sanitizer.truncate('abcde', 5)).to eq('abcde')
    end

    it 'ends a longer value with an ellipsis' do
      expect(sanitizer.truncate('abcdef', 5)).to eq('ab...')
    end

    it 'returns nil for nil' do
      expect(sanitizer.truncate(nil, 5)).to be_nil
    end
  end
end
