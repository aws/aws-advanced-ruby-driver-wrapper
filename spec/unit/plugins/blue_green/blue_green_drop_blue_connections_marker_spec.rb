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
require 'aws_advanced_ruby_driver_wrapper/plugins/blue_green/drop_blue_connections_marker'

RSpec.describe AwsAdvancedRubyDriverWrapper::Plugins::BlueGreen::DropBlueConnectionsMarker do
  let(:blue_hosts) { %w[blue.cluster-abc.us-east-1.rds.amazonaws.com 10.0.0.1] }
  let(:switchover_time_ns) { 1_000 }

  subject(:marker) { described_class.new(blue_hosts: blue_hosts, switchover_time_ns: switchover_time_ns) }

  describe '#initialize' do
    it 'generates a unique id by default' do
      other = described_class.new(blue_hosts: blue_hosts, switchover_time_ns: switchover_time_ns)
      expect(marker.id).not_to eq(other.id)
    end

    it 'is pending (not active) by default' do
      expect(marker.active?).to be(false)
    end

    it 'stores the blue hosts as a frozen set' do
      expect(marker.blue_hosts).to be_a(Set).and be_frozen
      expect(marker.blue_hosts).to contain_exactly(*blue_hosts)
    end

    it 'is frozen' do
      expect(marker).to be_frozen
    end
  end

  describe '#activated' do
    it 'returns an active copy that keeps the same identity, time, and hosts' do
      active = marker.activated
      expect(active.active?).to be(true)
      expect(active.id).to eq(marker.id)
      expect(active.switchover_time_ns).to eq(marker.switchover_time_ns)
      expect(active.blue_hosts).to eq(marker.blue_hosts)
    end

    it 'returns itself when already active' do
      active = marker.activated
      expect(active.activated).to equal(active)
    end
  end

  describe '#stale?' do
    let(:active_marker) { marker.activated }

    it 'is false while the marker is only pending' do
      expect(marker.stale?('10.0.0.1', switchover_time_ns - 1)).to be(false)
    end

    it 'is true for a blue host opened before the switchover' do
      expect(active_marker.stale?('10.0.0.1', switchover_time_ns - 1)).to be(true)
    end

    it 'is false for a connection opened at or after the switchover' do
      expect(active_marker.stale?('10.0.0.1', switchover_time_ns)).to be(false)
      expect(active_marker.stale?('10.0.0.1', switchover_time_ns + 1)).to be(false)
    end

    it 'is false for a host that is not in the blue host set' do
      expect(active_marker.stale?('green.cluster-abc.us-east-1.rds.amazonaws.com', switchover_time_ns - 1)).to be(false)
    end

    it 'is false when the host or open time is unknown' do
      expect(active_marker.stale?(nil, switchover_time_ns - 1)).to be(false)
      expect(active_marker.stale?('10.0.0.1', nil)).to be(false)
    end
  end
end
