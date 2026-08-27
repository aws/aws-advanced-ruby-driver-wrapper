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
require 'aws_advanced_ruby_driver_wrapper/plugins/kms_encryption/error_context'

RSpec.describe AwsAdvancedRubyDriverWrapper::Plugins::Encryption::ErrorContext do
  subject(:context) { described_class.builder }

  describe '.builder' do
    it 'starts empty' do
      expect(context).to be_empty
      expect(context.context).to eq({})
    end

    it 'returns itself from every helper, so the calls can be chained' do
      expect(context.table('users')).to be(context)
      expect(context.column('ssn')).to be(context)
      expect(context.retry_attempt(1, 3)).to be(context)
    end
  end

  describe '#context' do
    it 'hands back a copy, so a caller cannot edit the accumulated context' do
      context.table('users')
      copy = context.context
      copy[:table] = 'other'
      expect(context.context[:table]).to eq('users')
    end

    it 'drops entries with no value' do
      context.table(nil).column(nil).operation(nil)
      expect(context).to be_empty
    end
  end

  describe '#build_message' do
    it 'returns the message as it is when there is no context' do
      expect(context.build_message('Something failed')).to eq('Something failed')
    end

    it 'appends the whole context as key=value pairs' do
      context.table('users').column('ssn').algorithm('AES-256-GCM')
      expect(context.build_message('Something failed'))
        .to eq('Something failed [Context: table=users, column=ssn, algorithm=AES-256-GCM]')
    end
  end

  describe '#build_encryption_error_message' do
    it 'reads as a sentence' do
      message = context.table('users').column('ssn').operation('ENCRYPT').parameter_index(2)
                       .build_encryption_error_message('the data key was rejected')
      expect(message).to eq(
        'Encryption failed: the data key was rejected for column users.ssn during ENCRYPT (parameter index: 2)'
      )
    end

    it 'is just the prefix when nothing is known' do
      expect(context.build_encryption_error_message).to eq('Encryption failed')
      expect(context.build_encryption_error_message('   ')).to eq('Encryption failed')
    end

    it 'names a table on its own' do
      expect(context.table('users').build_encryption_error_message('boom'))
        .to eq('Encryption failed: boom for table users')
    end

    it 'names a column on its own' do
      expect(context.column('ssn').build_encryption_error_message('boom'))
        .to eq('Encryption failed: boom for column ssn')
    end

    it 'prefers the parameter index over the column index' do
      expect(context.parameter_index(2).column_index(5).build_encryption_error_message('boom'))
        .to eq('Encryption failed: boom (parameter index: 2)')
    end

    it 'names the column index when there is no parameter index' do
      expect(context.column_index(5).build_encryption_error_message('boom'))
        .to eq('Encryption failed: boom (column index: 5)')
    end

    it 'names the attempt that failed' do
      expect(context.retry_attempt(2, 3).build_encryption_error_message('boom'))
        .to eq('Encryption failed: boom (retry 2/3)')
    end

    # Anything that is not part of the sentence is listed at the end.
    it 'appends the remaining details in brackets' do
      message = context.table('users').algorithm('AES-256-GCM').data_type('STRING')
                       .cache_info('data_key', true)
                       .build_encryption_error_message('boom')
      expect(message).to eq(
        'Encryption failed: boom for table users [algorithm=AES-256-GCM, data_type=STRING, ' \
        'cache_type=data_key, cache_hit=true]'
      )
    end
  end

  describe 'the other message prefixes' do
    it 'labels a decryption failure' do
      expect(context.build_decryption_error_message('boom')).to eq('Decryption failed: boom')
    end

    it 'labels a key management failure' do
      expect(context.build_key_management_error_message('boom')).to eq('Key management operation failed: boom')
    end

    it 'labels a metadata failure' do
      expect(context.build_metadata_error_message('boom')).to eq('Metadata operation failed: boom')
    end
  end

  describe 'redaction' do
    it 'masks the key id' do
      expect(context.key_id('1234abcd-12ab-34cd-56ef-1234567890ab').context[:key_id]).to eq('1234***90ab')
    end

    it 'masks the account and region of the master key ARN' do
      expect(context.master_key_arn('arn:aws:kms:us-east-1:123456789012:key/1234abcd').context[:master_key_arn])
        .to eq('arn:aws:kms:***:***:key/1234abcd')
    end

    it 'masks the literals of the SQL' do
      expect(context.sql("SELECT * FROM users WHERE ssn = '123-45-6789'").context[:sql])
        .to eq("SELECT * FROM users WHERE ssn = '***'")
    end

    it 'truncates an over-long table name' do
      expect(context.table('t' * 60).context[:table].length).to eq(50)
    end
  end
end
