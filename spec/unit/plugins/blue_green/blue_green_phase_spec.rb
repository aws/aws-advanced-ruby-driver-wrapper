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
require 'aws_ruby_database_driver_wrapper/plugins/blue_green/phase'

RSpec.describe AwsRubyDatabaseDriverWrapper::Plugins::BlueGreen::Phase do
  let(:phase) { described_class }

  describe 'ordering' do
    it 'orders phases correctly' do
      expect(phase::NOT_CREATED).to be < phase::CREATED
      expect(phase::CREATED).to     be < phase::PREPARATION
      expect(phase::PREPARATION).to be < phase::IN_PROGRESS
      expect(phase::IN_PROGRESS).to be < phase::POST
      expect(phase::POST).to        be < phase::COMPLETED
    end
  end

  describe '.parse_phase' do
    {
      'AVAILABLE' => :CREATED,
      'SWITCHOVER_INITIATED' => :PREPARATION,
      'SWITCHOVER_IN_PROGRESS' => :IN_PROGRESS,
      'SWITCHOVER_IN_POST_PROCESSING' => :POST,
      'SWITCHOVER_COMPLETED' => :COMPLETED
    }.each do |raw, expected_key|
      it "maps '#{raw}' to #{expected_key}" do
        expect(phase.parse_phase(raw)).to eq(phase.const_get(expected_key))
      end
    end

    it 'is case-insensitive' do
      expect(phase.parse_phase('available')).to eq(phase::CREATED)
    end

    it 'returns NOT_CREATED for nil' do
      expect(phase.parse_phase(nil)).to eq(phase::NOT_CREATED)
    end

    it 'returns NOT_CREATED for empty string' do
      expect(phase.parse_phase('')).to eq(phase::NOT_CREATED)
    end

    it 'raises for unknown values' do
      expect { phase.parse_phase('UNKNOWN') }.to raise_error(ArgumentError)
    end
  end

  describe '#active_switchover_or_completed?' do
    it 'is false for NOT_CREATED and CREATED' do
      expect(phase::NOT_CREATED.active_switchover_or_completed?).to be false
      expect(phase::CREATED.active_switchover_or_completed?).to     be false
    end

    it 'is true for PREPARATION through COMPLETED' do
      [phase::PREPARATION, phase::IN_PROGRESS, phase::POST, phase::COMPLETED].each do |p|
        expect(p.active_switchover_or_completed?).to be true
      end
    end
  end

  describe '#to_s' do
    it 'returns the name string' do
      expect(phase::IN_PROGRESS.to_s).to eq('IN_PROGRESS')
    end
  end
end
