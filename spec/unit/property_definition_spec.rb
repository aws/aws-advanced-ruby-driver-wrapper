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
require 'aws_ruby_database_driver_wrapper/property_definition'

RSpec.describe AwsRubyDatabaseDriverWrapper::PropertyDefinition do
  describe '.wrapper_property?' do
    it 'returns true for known wrapper properties' do
      expect(described_class.wrapper_property?(:wrapper_plugins)).to be true
      expect(described_class.wrapper_property?(:cluster_id)).to be true
      expect(described_class.wrapper_property?(:failover_timeout_sec)).to be true
    end

    it 'returns false for driver properties' do
      expect(described_class.wrapper_property?(:host)).to be false
      expect(described_class.wrapper_property?(:port)).to be false
      expect(described_class.wrapper_property?(:dbname)).to be false
    end

    it 'accepts string keys' do
      expect(described_class.wrapper_property?('wrapper_plugins')).to be true
      expect(described_class.wrapper_property?('host')).to be false
    end
  end

  describe 'WrapperProperty#get' do
    it 'returns the value from props when present' do
      result = described_class::CLUSTER_ID.get({ cluster_id: 'my-cluster' })
      expect(result).to eq('my-cluster')
    end

    it 'returns the default when key is not in props' do
      result = described_class::CLUSTER_ID.get({})
      expect(result).to eq('1')
    end

    it 'returns user value even when it matches the default' do
      result = described_class::CLUSTER_ID.get({ cluster_id: '1' })
      expect(result).to eq('1')
    end
  end

  describe 'WrapperProperty#get_bool' do
    it 'returns boolean true from boolean value' do
      result = described_class::AUTO_SORT_PLUGIN_ORDER.get_bool({ auto_sort_plugin_order: true })
      expect(result).to be true
    end

    it 'returns boolean true from string "true"' do
      result = described_class::AUTO_SORT_PLUGIN_ORDER.get_bool({ auto_sort_plugin_order: 'true' })
      expect(result).to be true
    end

    it 'returns boolean false from string "false"' do
      result = described_class::AUTO_SORT_PLUGIN_ORDER.get_bool({ auto_sort_plugin_order: 'false' })
      expect(result).to be false
    end

    it 'returns default when not present' do
      result = described_class::AUTO_SORT_PLUGIN_ORDER.get_bool({})
      expect(result).to be true
    end
  end

  describe 'WrapperProperty#get_int' do
    it 'returns integer from integer value' do
      result = described_class::FAILOVER_TIMEOUT_SEC.get_int({ failover_timeout_sec: 120 })
      expect(result).to eq(120)
    end

    it 'returns integer from string value' do
      result = described_class::FAILOVER_TIMEOUT_SEC.get_int({ failover_timeout_sec: '120' })
      expect(result).to eq(120)
    end

    it 'returns default when not present' do
      result = described_class::FAILOVER_TIMEOUT_SEC.get_int({})
      expect(result).to eq(300)
    end
  end
end
