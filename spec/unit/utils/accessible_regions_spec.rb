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
require 'concurrent'
require 'aws_ruby_driver_wrapper/utils/accessible_regions'
require 'aws_ruby_driver_wrapper/host/host_info'

RSpec.describe AwsRubyDriverWrapper::Utils::AccessibleRegions do
  let(:host_info_class) { AwsRubyDriverWrapper::Host::HostInfo }

  describe '.parse' do
    it 'returns nil when the property is not set' do
      props = Concurrent::Map.new
      expect(described_class.parse(props)).to be_nil
    end

    it 'returns nil when the property is an empty string' do
      props = Concurrent::Map.new
      props[:accessible_regions] = ''
      expect(described_class.parse(props)).to be_nil
    end

    it 'returns nil when the property is whitespace only' do
      props = Concurrent::Map.new
      props[:accessible_regions] = '   '
      expect(described_class.parse(props)).to be_nil
    end

    it 'parses a single region' do
      props = Concurrent::Map.new
      props[:accessible_regions] = 'us-east-1'
      result = described_class.parse(props)
      expect(result).to be_a(Set)
      expect(result).to eq(Set['us-east-1'])
    end

    it 'parses multiple regions' do
      props = Concurrent::Map.new
      props[:accessible_regions] = 'us-east-1,us-west-2,eu-west-1'
      result = described_class.parse(props)
      expect(result).to eq(Set['us-east-1', 'us-west-2', 'eu-west-1'])
    end

    it 'trims whitespace and downcases' do
      props = Concurrent::Map.new
      props[:accessible_regions] = ' US-East-1 , us-WEST-2 '
      result = described_class.parse(props)
      expect(result).to eq(Set['us-east-1', 'us-west-2'])
    end

    it 'ignores empty entries from consecutive commas' do
      props = Concurrent::Map.new
      props[:accessible_regions] = 'us-east-1,,us-west-2,'
      result = described_class.parse(props)
      expect(result).to eq(Set['us-east-1', 'us-west-2'])
    end
  end

  describe '.filter_by_region' do
    let(:host_east) { host_info_class.new(host: 'writer.xyz.us-east-1.rds.amazonaws.com') }
    let(:host_west) { host_info_class.new(host: 'reader.xyz.us-west-2.rds.amazonaws.com') }
    let(:host_eu) { host_info_class.new(host: 'instance.xyz.eu-west-1.rds.amazonaws.com') }
    let(:hosts) { [host_east, host_west, host_eu] }

    it 'returns all hosts when accessible_regions is nil' do
      result = described_class.filter_by_region(hosts, nil)
      expect(result).to eq(hosts)
    end

    it 'filters hosts to only those in accessible regions' do
      regions = Set['us-east-1', 'eu-west-1']
      result = described_class.filter_by_region(hosts, regions)
      expect(result).to eq([host_east, host_eu])
    end

    it 'returns empty array when no hosts match' do
      regions = Set['ap-southeast-1']
      result = described_class.filter_by_region(hosts, regions)
      expect(result).to be_empty
    end

    it 'handles hosts with no parseable region' do
      non_rds_host = host_info_class.new(host: 'localhost')
      result = described_class.filter_by_region([non_rds_host], Set['us-east-1'])
      expect(result).to be_empty
    end
  end
end
