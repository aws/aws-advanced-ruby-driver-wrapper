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

require_relative '../../spec_helper'
require 'aws-sdk-core'
require 'aws_advanced_ruby_driver_wrapper/utils/aws_credentials_utils'

RSpec.describe AwsAdvancedRubyDriverWrapper::Utils::AwsCredentialsUtils do
  describe '.identity' do
    let(:credentials) { Aws::Credentials.new('AKID1', 'SECRET1') }

    it 'is the same for credentials with the same access key id' do
      expect(described_class.identity(credentials)).to eq(described_class.identity(Aws::Credentials.new('AKID1', 'OTHER')))
    end

    it 'differs for credentials with different access key ids' do
      expect(described_class.identity(credentials)).not_to eq(described_class.identity(Aws::Credentials.new('AKID2', 'SECRET1')))
    end

    it 'is a short hex digest that contains neither the access key id nor the secret key' do
      identity = described_class.identity(credentials)

      expect(identity).to match(/\A\h{#{described_class::IDENTITY_LENGTH}}\z/o)
      expect(identity).not_to include('AKID1')
      expect(identity).not_to include('SECRET1')
    end

    it 'reads the credentials a provider currently resolves to' do
      provider = double('Provider', credentials: credentials)

      expect(described_class.identity(provider)).to eq(described_class.identity(credentials))
    end

    it 'follows a provider whose credentials refresh to a new access key' do
      provider = double('Provider')
      allow(provider).to receive(:credentials).and_return(credentials, Aws::Credentials.new('AKID2', 'SECRET2'))

      expect(described_class.identity(provider)).not_to eq(described_class.identity(provider))
    end

    it 'never reads the secret key' do
      creds = instance_double(Aws::Credentials, access_key_id: 'AKID1')

      expect(described_class.identity(creds)).to eq(described_class.identity(credentials))
    end

    it 'uses a fixed value when there are no credentials' do
      expect(described_class.identity(nil)).to eq(described_class::NO_CREDENTIALS)
      expect(described_class.identity(double('Provider', credentials: nil))).to eq(described_class::NO_CREDENTIALS)
      expect(described_class.identity(Aws::Credentials.new('', ''))).to eq(described_class::NO_CREDENTIALS)
    end
  end
end
