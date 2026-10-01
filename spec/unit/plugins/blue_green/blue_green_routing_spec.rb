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
require 'aws_advanced_ruby_driver_wrapper/plugins/blue_green/routing/base_routing'
require 'aws_advanced_ruby_driver_wrapper/plugins/blue_green/routing/reject_connect_routing'
require 'aws_advanced_ruby_driver_wrapper/plugins/blue_green/routing/suspend_connect_routing'
require 'aws_advanced_ruby_driver_wrapper/plugins/blue_green/routing/suspend_execute_routing'
require 'aws_advanced_ruby_driver_wrapper/plugins/blue_green/routing/substitute_connect_routing'
require 'aws_advanced_ruby_driver_wrapper/plugins/blue_green/routing/suspend_until_corresponding_host_found_connect_routing'
require 'aws_advanced_ruby_driver_wrapper/plugins/blue_green/phase'
require 'aws_advanced_ruby_driver_wrapper/plugins/blue_green/role'
require 'aws_advanced_ruby_driver_wrapper/plugins/blue_green/status'
require 'aws_advanced_ruby_driver_wrapper/host/host_info'
require 'aws_advanced_ruby_driver_wrapper/host/host_availability'
require 'aws_advanced_ruby_driver_wrapper/errors'
require 'aws_advanced_ruby_driver_wrapper/property_definition'
require 'concurrent'

RSpec.describe AwsAdvancedRubyDriverWrapper::Plugins::BlueGreen::Routing do
  let(:bg)      { AwsAdvancedRubyDriverWrapper::Plugins::BlueGreen }
  let(:routing) { bg::Routing }
  let(:phase)   { bg::Phase }
  let(:role)    { bg::Role }
  let(:errors)  { AwsAdvancedRubyDriverWrapper::Errors }

  let(:host_val) { 'blue-instance.cluster-abc.us-east-1.rds.amazonaws.com' }
  let(:port_val) { 3306 }

  let(:host_info) { AwsAdvancedRubyDriverWrapper::Host::HostInfo.new(host: host_val, port: port_val) }
  let(:props)     { Concurrent::Map.new }

  describe 'BaseRouting#match?' do
    # Use RejectConnectRouting as a concrete carrier of BaseRouting
    def make_routing(host: nil, port: nil, role: nil)
      AwsAdvancedRubyDriverWrapper::Plugins::BlueGreen::Routing::RejectConnectRouting.new(host, port, role)
    end

    it 'matches when all fields are nil (wildcard)' do
      expect(make_routing.match?(host_info, role::SOURCE)).to be true
    end

    it 'matches when host, port, and role all match' do
      r = make_routing(host: host_val, port: port_val, role: role::SOURCE)
      expect(r.match?(host_info, role::SOURCE)).to be true
    end

    it 'does not match when host differs' do
      r = make_routing(host: 'other.host')
      expect(r.match?(host_info, role::SOURCE)).to be false
    end

    it 'does not match when port differs' do
      r = make_routing(port: 9999)
      expect(r.match?(host_info, role::SOURCE)).to be false
    end

    it 'does not match when role differs' do
      r = make_routing(role: role::TARGET)
      expect(r.match?(host_info, role::SOURCE)).to be false
    end

    it 'matches nil host_info when host field is nil' do
      expect(make_routing.match?(nil, nil)).to be true
    end
  end

  describe 'RejectConnectRouting' do
    subject { routing::RejectConnectRouting.new(nil, nil, role::SOURCE) }

    it 'always raises BlueGreenSwitchoverError' do
      expect { subject.apply }.to raise_error(errors::BlueGreenSwitchoverError)
    end
  end

  describe 'SuspendConnectRouting' do
    let(:bgd_id)          { 'bgd-001' }
    let(:storage_service) { double('storage_service') }
    let(:service_container) { double('service_container', storage_service: storage_service) }

    subject { routing::SuspendConnectRouting.new(nil, nil, role::SOURCE, bgd_id) }

    context 'when status is not IN_PROGRESS' do
      before do
        status = instance_double(bg::Status, current_phase: phase::POST)
        allow(storage_service).to receive(:get).and_return(status)
      end

      it 'returns nil (passes through)' do
        result = subject.apply(host_info, nil, props, true, service_container)
        expect(result).to be_nil
      end
    end

    context 'when status is nil' do
      before { allow(storage_service).to receive(:get).and_return(nil) }

      it 'returns nil without blocking' do
        result = subject.apply(host_info, nil, props, true, service_container)
        expect(result).to be_nil
      end
    end

    context 'when status stays IN_PROGRESS past the timeout' do
      before do
        props[AwsAdvancedRubyDriverWrapper::PropertyDefinition::BG_CONNECT_TIMEOUT_SEC.name] = 0.05
        status = instance_double(bg::Status, current_phase: phase::IN_PROGRESS, wait: nil, notify: nil)
        allow(storage_service).to receive(:get).and_return(status)
      end

      it 'raises BlueGreenTimeoutError' do
        expect { subject.apply(host_info, nil, props, true, service_container) }
          .to raise_error(errors::BlueGreenTimeoutError)
      end
    end
  end

  describe 'SuspendExecuteRouting' do
    let(:bgd_id)          { 'bgd-001' }
    let(:storage_service) { double('storage_service') }

    subject { routing::SuspendExecuteRouting.new(nil, nil, role::SOURCE, bgd_id) }

    context 'when status is not IN_PROGRESS' do
      before do
        status = instance_double(bg::Status, current_phase: phase::POST)
        allow(storage_service).to receive(:get).and_return(status)
      end

      it 'returns nil' do
        expect(subject.apply('connection.query', props, storage_service)).to be_nil
      end
    end

    context 'when status stays IN_PROGRESS past the timeout' do
      before do
        props[AwsAdvancedRubyDriverWrapper::PropertyDefinition::BG_CONNECT_TIMEOUT_SEC.name] = 0.05
        status = instance_double(bg::Status, current_phase: phase::IN_PROGRESS, wait: nil, notify: nil)
        allow(storage_service).to receive(:get).and_return(status)
      end

      it 'raises BlueGreenTimeoutError' do
        expect { subject.apply('connection.query', props, storage_service) }
          .to raise_error(errors::BlueGreenTimeoutError)
      end
    end
  end

  describe 'SubstituteConnectRouting' do
    let(:connection)      { double('connection') }
    let(:plugin_manager)  { double('plugin_manager') }
    let(:dialect_service) { double('dialect_service', login_error?: false) }
    let(:service_container) do
      double('service_container', plugin_manager: plugin_manager, dialect_service: dialect_service)
    end

    context 'when substitute host is an IP address without IAM' do
      let(:ip_host) { AwsAdvancedRubyDriverWrapper::Host::HostInfo.new(host: '10.0.1.1', port: 3306) }

      before do
        allow(plugin_manager).to receive(:plugin_in_use?).and_return(false)
        allow(plugin_manager).to receive(:connect).and_return(connection)
      end

      subject { routing::SubstituteConnectRouting.new(host_val, nil, role::SOURCE, ip_host, [], nil) }

      it 'connects to the IP host directly' do
        expect(plugin_manager).to receive(:connect).with(ip_host, props, true, plugin_to_skip: nil).and_return(connection)
        subject.apply(host_info, props, props, true, service_container)
      end
    end

    context 'when substitute host is an IP address with IAM enabled' do
      let(:ip_host)   { AwsAdvancedRubyDriverWrapper::Host::HostInfo.new(host: '10.0.1.1', port: 3306) }
      let(:iam_host1) { AwsAdvancedRubyDriverWrapper::Host::HostInfo.new(host: 'green-instance.cluster-abc.us-east-1.rds.amazonaws.com', port: 3306) }
      let(:iam_host2) { AwsAdvancedRubyDriverWrapper::Host::HostInfo.new(host: 'blue-instance.cluster-abc.us-east-1.rds.amazonaws.com', port: 3306) }
      let(:driver_props) { Concurrent::Map.new }
      let(:connection_service) { double('connection_service', driver_props: driver_props) }

      before do
        allow(plugin_manager).to receive(:plugin_in_use?).and_return(true)
        allow(service_container).to receive(:connection_service).and_return(connection_service)
      end

      subject { routing::SubstituteConnectRouting.new(host_val, nil, role::SOURCE, ip_host, [iam_host1, iam_host2], nil) }

      it 'tries IAM hosts in order and returns the first successful connection' do
        allow(plugin_manager).to receive(:internal_connect)
          .with(anything, anything, anything, anything, plugin_to_skip: anything).and_return(connection)
        result = subject.apply(host_info, driver_props, props, true, service_container)
        expect(result).to eq(connection)
      end

      it 'skips a login error and tries the next IAM host' do
        login_error = StandardError.new('Access denied')
        allow(dialect_service).to receive(:login_error?).with(login_error).and_return(true)
        call_count = 0
        allow(plugin_manager).to receive(:internal_connect) do
          call_count += 1
          call_count == 1 ? raise(login_error) : connection
        end
        result = subject.apply(host_info, driver_props, props, true, service_container)
        expect(result).to eq(connection)
      end

      it 'raises if IAM hosts list is empty' do
        r = routing::SubstituteConnectRouting.new(host_val, nil, role::SOURCE, ip_host, [], nil)
        expect { r.apply(host_info, driver_props, props, true, service_container) }.to raise_error(StandardError, /iam_host/)
      end

      it 'calls the notify callback with the successful iam_host' do
        notified = []
        r = routing::SubstituteConnectRouting.new(host_val, nil, role::SOURCE, ip_host, [iam_host1], ->(h) { notified << h })
        allow(plugin_manager).to receive(:internal_connect).and_return(connection)
        r.apply(host_info, driver_props, props, true, service_container)
        expect(notified).to eq([iam_host1.host])
      end
    end
    context 'when substitute host is a hostname (the MySQL switchover path)' do
      let(:sub_host) do
        AwsAdvancedRubyDriverWrapper::Host::HostInfo.new(
          host: 'green-instance.cluster-abc.us-east-1.rds.amazonaws.com', port: 3306
        )
      end

      before do
        allow(plugin_manager).to receive(:plugin_in_use?).and_return(false)
      end

      subject { routing::SubstituteConnectRouting.new(host_val, nil, role::SOURCE, sub_host, [], nil) }

      it 'passes plugin_to_skip on the user-facing connect so it does not recurse into BG routing' do
        bg_plugin = double('bg_plugin')
        expect(plugin_manager).to receive(:connect)
          .with(sub_host, props, true, plugin_to_skip: bg_plugin).and_return(connection)
        result = subject.apply(host_info, props, props, true, service_container, is_internal: false, bg_plugin: bg_plugin)
        expect(result).to eq(connection)
      end

      it 'passes plugin_to_skip on an internal monitoring connect' do
        bg_plugin = double('bg_plugin')
        expect(plugin_manager).to receive(:internal_connect)
          .with(sub_host, props, props, true, plugin_to_skip: bg_plugin).and_return(connection)
        subject.apply(host_info, props, props, true, service_container, is_internal: true, bg_plugin: bg_plugin)
      end
    end
  end

  describe 'SuspendUntilCorrespondingHostFoundConnectRouting' do
    let(:bgd_id)          { 'bgd-001' }
    let(:storage_service) { double('storage_service') }
    let(:service_container) { double('service_container', storage_service: storage_service) }

    subject { routing::SuspendUntilCorrespondingHostFoundConnectRouting.new(host_val, nil, role::SOURCE, bgd_id) }

    context 'when status is COMPLETED immediately' do
      before do
        status = instance_double(bg::Status,
                                 current_phase: phase::COMPLETED,
                                 corresponding_hosts: {})
        allow(storage_service).to receive(:get).and_return(status)
      end

      it 'returns nil without blocking' do
        result = subject.apply(host_info, nil, props, true, service_container)
        expect(result).to be_nil
      end
    end

    context 'when status is nil' do
      before { allow(storage_service).to receive(:get).and_return(nil) }

      it 'returns nil' do
        expect(subject.apply(host_info, nil, props, true, service_container)).to be_nil
      end
    end

    context 'when corresponding host is found on second poll' do
      let(:green_host) { AwsAdvancedRubyDriverWrapper::Host::HostInfo.new(host: 'green-instance.cluster-abc.us-east-1.rds.amazonaws.com', port: 3306) }

      it 'returns nil once the host is found' do
        waiting_status = instance_double(bg::Status,
                                         current_phase: phase::POST,
                                         corresponding_hosts: { host_val => [host_info, nil] },
                                         wait: nil, notify: nil)
        resolved_status = instance_double(bg::Status,
                                          current_phase: phase::POST,
                                          corresponding_hosts: { host_val => [host_info, green_host] })
        allow(storage_service).to receive(:get).and_return(waiting_status, resolved_status)
        result = subject.apply(host_info, nil, props, true, service_container)
        expect(result).to be_nil
      end
    end

    context 'when timeout elapses before host is found' do
      before do
        props[AwsAdvancedRubyDriverWrapper::PropertyDefinition::BG_CONNECT_TIMEOUT_SEC.name] = 0.05
        status = instance_double(bg::Status,
                                 current_phase: phase::POST,
                                 corresponding_hosts: { host_val => [host_info, nil] },
                                 wait: nil, notify: nil)
        allow(storage_service).to receive(:get).and_return(status)
      end

      it 'raises BlueGreenTimeoutError' do
        expect { subject.apply(host_info, nil, props, true, service_container) }
          .to raise_error(errors::BlueGreenTimeoutError)
      end
    end
  end
end
