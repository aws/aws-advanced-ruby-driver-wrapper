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

# frozen_string_literal: true

require_relative '../../../spec_helper'
require 'aws_ruby_driver_wrapper/plugins/blue_green/role'

RSpec.describe AwsRubyDriverWrapper::Plugins::BlueGreen::Role do
  let(:role) { described_class }

  describe '.parse_role' do
    it 'maps BLUE_GREEN_DEPLOYMENT_SOURCE to SOURCE' do
      expect(role.parse_role('BLUE_GREEN_DEPLOYMENT_SOURCE', '1.0')).to eq(role::SOURCE)
    end

    it 'maps BLUE_GREEN_DEPLOYMENT_TARGET to TARGET' do
      expect(role.parse_role('BLUE_GREEN_DEPLOYMENT_TARGET', '1.0')).to eq(role::TARGET)
    end

    it 'is case-insensitive' do
      expect(role.parse_role('blue_green_deployment_source', '1.0')).to eq(role::SOURCE)
    end

    it 'raises for an unknown role value' do
      expect { role.parse_role('UNKNOWN_ROLE', '1.0') }.to raise_error(ArgumentError, %r{Unknown Blue/Green role})
    end

    it 'raises for an unknown version' do
      expect { role.parse_role('BLUE_GREEN_DEPLOYMENT_SOURCE', '2.0') }.to raise_error(ArgumentError, %r{Unknown Blue/Green version})
    end

    it 'raises for a blank value' do
      expect { role.parse_role('   ', '1.0') }.to raise_error(ArgumentError, /blank/)
    end

    it 'raises for nil' do
      expect { role.parse_role(nil, '1.0') }.to raise_error(ArgumentError, /blank/)
    end
  end
end
