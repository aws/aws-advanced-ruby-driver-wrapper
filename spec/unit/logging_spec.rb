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

require_relative '../spec_helper'
require 'concurrent'
require 'aws_advanced_ruby_driver_wrapper/logging'

RSpec.describe AwsAdvancedRubyDriverWrapper do
  let(:redacted) { AwsAdvancedRubyDriverWrapper::REDACTED }

  describe '.mask_properties' do
    it 'redacts keys that contain a secret marker, in any case' do
      masked = described_class.mask_properties(
        password: 'p', iam_token: 't', SecretValue: 's', aws_credentials_provider: 'c', user: 'admin'
      )

      expect(masked).to eq(password: redacted, iam_token: redacted, SecretValue: redacted,
                           aws_credentials_provider: redacted, user: 'admin')
    end

    it 'accepts a Concurrent::Map and returns a plain Hash' do
      props = Concurrent::Map.new
      props[:password] = 'p'
      props[:host] = 'db.example.com'

      expect(described_class.mask_properties(props)).to eq(password: redacted, host: 'db.example.com')
    end

    it 'does not change the properties it is given' do
      props = { password: 'p' }
      described_class.mask_properties(props)

      expect(props).to eq(password: 'p')
    end

    it 'returns an empty Hash for nil' do
      expect(described_class.mask_properties(nil)).to eq({})
    end

    it 'also redacts the extra key names it is given, matched exactly and in any case' do
      masked = described_class.mask_properties({ pwd: 'p', pwd_hint: 'h', user: 'admin' }, ['PWD'])

      expect(masked).to eq(pwd: redacted, pwd_hint: 'h', user: 'admin')
    end

    it 'ignores nil extra key names' do
      expect(described_class.mask_properties({ user: 'admin' }, [nil])).to eq(user: 'admin')
    end
  end
end
