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
require 'aws_advanced_ruby_driver_wrapper/plugins/blue_green/iam_host_tracker'

RSpec.describe AwsAdvancedRubyDriverWrapper::Plugins::BlueGreen::IamHostTracker do
  let(:on_all_changed) { double('callback', call: nil) }
  subject(:tracker) { described_class.new(on_all_changed: on_all_changed.method(:call)) }

  let(:green)  { 'green-host.cluster-abc.us-east-1.rds.amazonaws.com' }
  let(:blue)   { 'blue-host.cluster-abc.us-east-1.rds.amazonaws.com' }
  let(:green2) { 'green-host2.cluster-abc.us-east-1.rds.amazonaws.com' }
  let(:blue2)  { 'blue-host2.cluster-abc.us-east-1.rds.amazonaws.com' }

  describe '#connected?' do
    it 'returns false before any registration' do
      expect(tracker.connected?(green, blue)).to be false
    end

    it 'returns true after registering the pair' do
      tracker.register(green, blue)
      expect(tracker.connected?(green, blue)).to be true
    end

    it 'returns false for a different iam_host' do
      tracker.register(green, blue)
      expect(tracker.connected?(green, 'other.host')).to be false
    end
  end

  describe '#all_changed?' do
    it 'is false initially' do
      expect(tracker.all_changed?).to be false
    end

    it 'is false when connect_host == iam_host (same name, no rename)' do
      tracker.register(green, green)
      expect(tracker.all_changed?).to be false
    end

    it 'becomes true when all registered hosts have connected with a different iam_host' do
      tracker.register(green, blue)
      expect(tracker.all_changed?).to be true
    end

    it 'stays false until all hosts have changed' do
      # Register green2 first (same name = not changed), then green (different = changed).
      # At this point green2 has no rename yet, so all_changed? must stay false.
      tracker.register(green2, green2)
      tracker.register(green, blue)
      expect(tracker.all_changed?).to be false

      tracker.register(green2, blue2)
      expect(tracker.all_changed?).to be true
    end

    it 'fires on_all_changed callback exactly once' do
      expect(on_all_changed).to receive(:call).once
      tracker.register(green, blue)
      tracker.register(green, blue) # duplicate — should not re-fire
    end
  end

  describe '#size' do
    it 'counts distinct connect_hosts' do
      expect(tracker.size).to eq(0)
      tracker.register(green, blue)
      tracker.register(green, 'other')
      tracker.register(green2, blue2)
      expect(tracker.size).to eq(2)
    end
  end

  describe '#clear' do
    it 'resets all state' do
      tracker.register(green, blue)
      tracker.clear
      expect(tracker.connected?(green, blue)).to be false
      expect(tracker.all_changed?).to be false
      expect(tracker.size).to eq(0)
      expect(tracker.green_host_change_name_times).to be_empty
    end
  end

  describe '#green_host_change_name_times' do
    it 'records a timestamp when a host connects with a different iam_host' do
      tracker.register(green, blue)
      expect(tracker.green_host_change_name_times[green]).to be_a(Time)
    end

    it 'does not record a timestamp when connect_host == iam_host' do
      tracker.register(green, green)
      expect(tracker.green_host_change_name_times).not_to have_key(green)
    end

    it 'only records the first occurrence' do
      tracker.register(green, blue)
      first_time = tracker.green_host_change_name_times[green]
      sleep(0.01)
      tracker.register(green, 'another-blue')
      expect(tracker.green_host_change_name_times[green]).to eq(first_time)
    end
  end
end
