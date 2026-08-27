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
require 'aws_advanced_ruby_driver_wrapper/plugins/blue_green/switchover_state'
require 'aws_advanced_ruby_driver_wrapper/plugins/blue_green/phase'
require 'aws_advanced_ruby_driver_wrapper/plugins/blue_green/role'
require 'aws_advanced_ruby_driver_wrapper/plugins/blue_green/interim_status'
require 'aws_advanced_ruby_driver_wrapper/plugins/blue_green/iam_host_tracker'

RSpec.describe AwsAdvancedRubyDriverWrapper::Plugins::BlueGreen::SwitchoverState do
  let(:bg)    { AwsAdvancedRubyDriverWrapper::Plugins::BlueGreen }
  let(:phase) { bg::Phase }
  let(:role)  { bg::Role }

  let(:monitor_reset_events) { [] }
  let(:events)               { [] }

  subject(:state) do
    described_class.new(
      on_monitor_reset: ->(name) { monitor_reset_events << name },
      on_event: ->(name) { events << name }
    )
  end

  let(:iam_tracker) { bg::IamHostTracker.new(on_all_changed: -> {}) }

  def source_status(ip_changed: false, endpoints_removed: false, topology_changed: false)
    bg::InterimStatus.new(phase::IN_PROGRESS, '1.0', 3306, nil, nil, {}, {}, Set.new,
                          ip_changed, endpoints_removed, topology_changed)
  end

  def target_status(ip_changed: false, endpoints_removed: false, topology_changed: false)
    bg::InterimStatus.new(phase::IN_PROGRESS, '1.0', 3306, nil, nil, {}, {}, Set.new,
                          ip_changed, endpoints_removed, topology_changed)
  end

  describe '#update_dns_flags' do
    context 'blue DNS update' do
      it 'sets blue_dns_update_completed when source reports all_start_topology_ip_changed' do
        state.update_dns_flags('bgd-1', role::SOURCE, source_status(ip_changed: true))
        expect(state.blue_dns_update_completed).to be true
      end

      it 'records a Blue DNS updated event' do
        state.update_dns_flags('bgd-1', role::SOURCE, source_status(ip_changed: true))
        expect(events).to include('Blue DNS updated')
      end

      it 'does not set the flag when ip_changed is false' do
        state.update_dns_flags('bgd-1', role::SOURCE, source_status(ip_changed: false))
        expect(state.blue_dns_update_completed).to be false
      end

      it 'is idempotent — fires the event only once' do
        state.update_dns_flags('bgd-1', role::SOURCE, source_status(ip_changed: true))
        state.update_dns_flags('bgd-1', role::SOURCE, source_status(ip_changed: true))
        expect(events.count('Blue DNS updated')).to eq(1)
      end
    end

    context 'green DNS removed' do
      it 'sets green_dns_removed when target reports all_start_topology_endpoints_removed' do
        state.update_dns_flags('bgd-1', role::TARGET, target_status(endpoints_removed: true))
        expect(state.green_dns_removed).to be true
      end

      it 'records a Green DNS removed event' do
        state.update_dns_flags('bgd-1', role::TARGET, target_status(endpoints_removed: true))
        expect(events).to include('Green DNS removed')
      end

      it 'is idempotent' do
        state.update_dns_flags('bgd-1', role::TARGET, target_status(endpoints_removed: true))
        state.update_dns_flags('bgd-1', role::TARGET, target_status(endpoints_removed: true))
        expect(events.count('Green DNS removed')).to eq(1)
      end
    end

    context 'green topology changed' do
      it 'sets green_topology_changed when target reports all_topology_changed' do
        state.update_dns_flags('bgd-1', role::TARGET, target_status(topology_changed: true))
        expect(state.green_topology_changed).to be true
      end

      it 'fires a monitor reset for the topology event' do
        state.update_dns_flags('bgd-1', role::TARGET, target_status(topology_changed: true))
        expect(monitor_reset_events).not_to be_empty
      end

      it 'fires the monitor reset only once' do
        state.update_dns_flags('bgd-1', role::TARGET, target_status(topology_changed: true))
        state.update_dns_flags('bgd-1', role::TARGET, target_status(topology_changed: true))
        expect(monitor_reset_events.size).to eq(1)
      end
    end

    it 'ignores topology/endpoint flags for SOURCE role' do
      state.update_dns_flags('bgd-1', role::SOURCE, source_status(endpoints_removed: true, topology_changed: true))
      expect(state.green_dns_removed).to be false
      expect(state.green_topology_changed).to be false
    end
  end

  describe '#trigger_in_progress_monitor_reset' do
    it 'fires a monitor reset event' do
      state.trigger_in_progress_monitor_reset
      expect(monitor_reset_events).not_to be_empty
    end

    it 'fires only once' do
      state.trigger_in_progress_monitor_reset
      state.trigger_in_progress_monitor_reset
      expect(monitor_reset_events.size).to eq(1)
    end
  end

  describe '#reset' do
    it 'clears all flags and allows monitor resets to fire again' do
      state.update_dns_flags('bgd-1', role::SOURCE, source_status(ip_changed: true))
      state.update_dns_flags('bgd-1', role::TARGET, target_status(endpoints_removed: true, topology_changed: true))
      state.trigger_in_progress_monitor_reset
      # before reset: topology fired 1, in_progress fired 1 = 2 total
      resets_before = monitor_reset_events.size

      state.reset

      expect(state.blue_dns_update_completed).to be false
      expect(state.green_dns_removed).to be false
      expect(state.green_topology_changed).to be false

      # After reset, both one-shot flags are cleared so each fires once more
      state.trigger_in_progress_monitor_reset
      expect(monitor_reset_events.size).to eq(resets_before + 1)
    end
  end
end
