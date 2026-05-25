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
require 'aws_ruby_database_driver_wrapper/utils/connection_config'
require 'aws_ruby_database_driver_wrapper/services/connection_service'
require 'aws_ruby_database_driver_wrapper/property_definition'

RSpec.describe AwsRubyDatabaseDriverWrapper::Utils::ConnectionConfig do
  describe '#initialize' do
    it 'sets defaults for all attributes' do
      config = described_class.new
      expect(config.wrapper_props).to eq({})
      expect(config.driver_props).to eq({})
      expect(config.initial_host_info).to be_nil
      expect(config.driver_name).to be_nil
    end

    it 'accepts keyword arguments' do
      config = described_class.new(
        wrapper_props: { wrapper_plugins: 'failover' },
        driver_props: { host: 'myhost' },
        driver_name: :postgresql
      )
      expect(config.wrapper_props).to eq({ wrapper_plugins: 'failover' })
      expect(config.driver_props).to eq({ host: 'myhost' })
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
