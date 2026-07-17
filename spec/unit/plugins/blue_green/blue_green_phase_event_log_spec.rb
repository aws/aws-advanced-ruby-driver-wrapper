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
require 'aws_ruby_database_driver_wrapper/plugins/blue_green/phase_event_log'
require 'aws_ruby_database_driver_wrapper/plugins/blue_green/phase'

RSpec.describe AwsRubyDatabaseDriverWrapper::Plugins::BlueGreen::PhaseEventLog do
  let(:phase) { AwsRubyDatabaseDriverWrapper::Plugins::BlueGreen::Phase }

  subject(:log) { described_class.new }

  describe '#record' do
    it 'stores an entry' do
      log.record('IN_PROGRESS', '')
      expect(log.any?).to be true
    end

    it 'is idempotent — second call with same label is ignored' do
      log.record('IN_PROGRESS', '')
      first_entry = log.instance_variable_get(:@entries)['IN_PROGRESS']
      sleep(0.01)
      log.record('IN_PROGRESS', '')
      expect(log.instance_variable_get(:@entries)['IN_PROGRESS']).to equal(first_entry)
    end

    it 'treats rollback suffix as a distinct key' do
      log.record('CREATED', '')
      log.record('CREATED', ' (rollback)')
      entries = log.instance_variable_get(:@entries)
      expect(entries.keys).to include('CREATED', 'CREATED (rollback)')
    end
  end

  describe '#clear' do
    it 'removes all entries' do
      log.record('CREATED', '')
      log.clear
      expect(log.any?).to be false
    end
  end

  describe '#summary' do
    before do
      log.record('CREATED',     '', phase: phase::CREATED)
      log.record('IN_PROGRESS', '', phase: phase::IN_PROGRESS)
      log.record('COMPLETED',   '', phase: phase::COMPLETED)
    end

    it 'includes COMPLETED in the header for a normal switchover' do
      expect(log.summary('bgd-001', false)).to include('COMPLETED')
    end

    it 'includes ROLLED BACK in the header for a rollback' do
      expect(log.summary('bgd-001', true)).to include('ROLLED BACK')
    end

    it 'includes the bgd_id' do
      expect(log.summary('bgd-001', false)).to include('bgd-001')
    end

    it 'lists all recorded event labels' do
      summary = log.summary('bgd-001', false)
      expect(summary).to include('CREATED')
      expect(summary).to include('IN_PROGRESS')
      expect(summary).to include('COMPLETED')
    end
  end
end
