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

require 'rspec'
require 'aws_advanced_ruby_driver_wrapper/utils/connection_config'
require 'aws_advanced_ruby_driver_wrapper/services/connection_service'
require 'aws_advanced_ruby_driver_wrapper/property_definition'

RSpec.describe AwsAdvancedRubyDriverWrapper::Utils::ConnectionConfig do
  describe '#initialize' do
    it 'sets defaults for all attributes' do
      config = described_class.new
      expect(config.wrapper_props).to be_empty
      expect(config.driver_props).to be_empty
      expect(config.initial_host_info).to be_nil
      expect(config.driver_name).to be_nil
    end

    it 'accepts keyword arguments' do
      config = described_class.new(
        wrapper_props: { wrapper_plugins: 'failover' },
        driver_props: { host: 'myhost' },
        driver_name: :postgresql
      )
      expect(config.wrapper_props[:wrapper_plugins]).to eq('failover')
      expect(config.driver_props[:host]).to eq('myhost')
      expect(config.driver_name).to eq(:postgresql)
    end
  end

  describe '#cluster_id' do
    it 'returns the cluster_id from wrapper_config' do
      config = described_class.new(wrapper_props: { cluster_id: 'my-cluster' })
      expect(config.cluster_id).to eq('my-cluster')
    end

    it 'returns default cluster_id when not specified' do
      config = described_class.new
      expect(config.cluster_id).to eq('1')
    end
  end

  describe '#inspect' do
    let(:redacted) { AwsAdvancedRubyDriverWrapper::REDACTED }

    it 'redacts secrets in every property map' do
      config = described_class.new(
        wrapper_props: { secret_id: 'my-secret' },
        driver_props: { user: 'admin', password: 'hunter2' },
        prefixed_wrapper_config: { monitoring_password: 'm' },
        prefixed_driver_config: { password: 'd' }
      )

      expect(config.inspect).not_to include('hunter2', 'my-secret', '"m"', '"d"')
      expect(config.inspect).to include('admin')
    end

    # The IAM token is passed under a property whose name is configurable, so a name with none of
    # the usual secret markers must still be redacted.
    it 'redacts the configured IAM token property' do
      config = described_class.new(
        wrapper_props: { iam_access_token_property_name: :pwd },
        driver_props: { user: 'admin', pwd: 'iam-token-value' }
      )

      expect(config.inspect).not_to include('iam-token-value')
      expect(config.inspect).to include("pwd: #{redacted.inspect}").or include(":pwd=>#{redacted.inspect}")
    end

    it 'redacts the configured IAM token property when it is configured as a string' do
      config = described_class.new(
        wrapper_props: { iam_access_token_property_name: 'pwd' },
        driver_props: { pwd: 'iam-token-value' }
      )

      expect(config.inspect).not_to include('iam-token-value')
    end

    it 'applies the same redaction to #to_s and pretty printing' do
      config = described_class.new(
        wrapper_props: { iam_access_token_property_name: :pwd },
        driver_props: { pwd: 'iam-token-value' }
      )

      expect(config.to_s).not_to include('iam-token-value')
      expect(PP.pp(config, +'')).not_to include('iam-token-value')
    end

    it 'does not fail when the wrapper properties are missing' do
      config = described_class.new(wrapper_props: nil, driver_props: { password: 'p' })

      expect(config.inspect).not_to include('"p"')
    end
  end

  describe 'mutability' do
    it 'allows plugins to modify driver_config' do
      config = described_class.new(driver_props: { host: 'original' })
      config.driver_props[:password] = 'iam-token-123'
      expect(config.driver_props[:password]).to eq('iam-token-123')
    end

    it 'allows plugins to modify wrapper_config' do
      config = described_class.new(wrapper_props: {})
      config.wrapper_props[:wrapper_plugins] = 'failover'
      expect(config.wrapper_props[:wrapper_plugins]).to eq('failover')
    end
  end
end
