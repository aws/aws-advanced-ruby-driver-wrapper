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
require 'aws_ruby_driver_wrapper/monitoring/monitor'
require 'aws_ruby_driver_wrapper/services/monitor_service'
require 'aws_ruby_driver_wrapper/utils/events/batching_event_publisher'

RSpec.describe AwsRubyDriverWrapper::Services::MonitorService do
  let(:test_monitor_class) do
    Class.new(AwsRubyDriverWrapper::Monitoring::Monitor) do
      def monitor
        sleep(0.01) until stopped?
      end
    end
  end

  let(:service_container) { double('service_container') }
  let(:event_publisher) { AwsRubyDriverWrapper::Utils::Events::BatchingEventPublisher.new(message_interval_sec: 0.1) }

  let(:monitor_service) do
    described_class.new(event_publisher: event_publisher)
  end

  after do
    monitor_service.shutdown(grace_period: 2)
    event_publisher.release_resources
  end

  describe '#register_type' do
    it 'registers a new type' do
      monitor_service.register_type(:test_monitor, expiration_timeout_sec: 1)
      monitor = monitor_service.run_if_absent(:test_monitor, 'key1', service_container) { |_| test_monitor_class.new }
      expect(monitor).to be_a(test_monitor_class)
    end

    it 'is a no-op on duplicate registration' do
      monitor_service.register_type(:test_monitor, expiration_timeout_sec: 1)
      monitor_service.register_type(:test_monitor, expiration_timeout_sec: 1)
      monitor = monitor_service.run_if_absent(:test_monitor, 'key1', service_container) { |_| test_monitor_class.new }
      expect(monitor).to be_a(test_monitor_class)
    end
  end

  describe '#run_if_absent' do
    before { monitor_service.register_type(:test_monitor, expiration_timeout_sec: 1) }

    it 'creates and starts a monitor' do
      monitor = monitor_service.run_if_absent(:test_monitor, 'key1', service_container) { |_| test_monitor_class.new }
      sleep(0.05)
      expect(monitor.state).to eq(:running)
    end

    it 'returns existing monitor for same key' do
      m1 = monitor_service.run_if_absent(:test_monitor, 'key1', service_container) { |_| test_monitor_class.new }
      m2 = monitor_service.run_if_absent(:test_monitor, 'key1', service_container) { |_| test_monitor_class.new }
      expect(m1).to equal(m2)
    end

    it 'raises if type not registered' do
      expect do
        monitor_service.run_if_absent(:unregistered, 'key1', service_container) { |_| test_monitor_class.new }
      end.to raise_error(ArgumentError, /not registered/)
    end
  end

  describe '#get' do
    before { monitor_service.register_type(:test_monitor, expiration_timeout_sec: 1) }

    it 'retrieves a monitor by class and key' do
      monitor = monitor_service.run_if_absent(:test_monitor, 'key1', service_container) { |_| test_monitor_class.new }
      expect(monitor_service.get(:test_monitor, 'key1')).to equal(monitor)
    end

    it 'returns nil for missing key' do
      expect(monitor_service.get(:test_monitor, 'missing')).to be_nil
    end
  end

  describe '#stop_and_remove' do
    before { monitor_service.register_type(:test_monitor, expiration_timeout_sec: 1) }

    it 'stops and removes a monitor' do
      monitor = monitor_service.run_if_absent(:test_monitor, 'key1', service_container) { |_| test_monitor_class.new }
      sleep(0.05)
      monitor_service.stop_and_remove(:test_monitor, 'key1')
      expect(monitor.state).to eq(:stopped)
      expect(monitor_service.get(:test_monitor, 'key1')).to be_nil
    end
  end

  describe '#stop_and_remove_all' do
    before { monitor_service.register_type(:test_monitor, expiration_timeout_sec: 1) }

    it 'stops all monitors' do
      m1 = monitor_service.run_if_absent(:test_monitor, 'k1', service_container) { |_| test_monitor_class.new }
      m2 = monitor_service.run_if_absent(:test_monitor, 'k2', service_container) { |_| test_monitor_class.new }
      sleep(0.05)
      monitor_service.stop_and_remove_all
      expect(m1.state).to eq(:stopped)
      expect(m2.state).to eq(:stopped)
    end
  end

  describe '#shutdown' do
    before { monitor_service.register_type(:test_monitor, expiration_timeout_sec: 1) }

    it 'stops cleanup thread and all monitors' do
      monitor = monitor_service.run_if_absent(:test_monitor, 'key1', service_container) { |_| test_monitor_class.new }
      sleep(0.05)
      monitor_service.shutdown(grace_period: 2)
      expect(monitor.state).to eq(:stopped)
    end
  end
end
