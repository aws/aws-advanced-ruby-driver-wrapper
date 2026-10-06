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
require 'aws_advanced_ruby_driver_wrapper/monitoring/monitor_connection'

RSpec.describe AwsAdvancedRubyDriverWrapper::Monitoring::MonitorConnection do
  let(:mock_driver_dialect) { double('DriverDialect', close_connection: nil) }
  subject(:monitor_connection) { described_class.new(mock_driver_dialect) }

  let(:conn1) { instance_double('Connection', close: nil) }
  let(:conn2) { instance_double('Connection', close: nil) }

  describe '#get' do
    it 'returns nil initially' do
      expect(monitor_connection.get).to be_nil
    end

    it 'returns the connection after set' do
      monitor_connection.set(conn1)
      expect(monitor_connection.get).to eq(conn1)
    end
  end

  describe '#set' do
    it 'stores the connection' do
      monitor_connection.set(conn1)
      expect(monitor_connection.get).to eq(conn1)
    end

    it 'closes the old connection when replacing' do
      monitor_connection.set(conn1)
      monitor_connection.set(conn2)
      expect(mock_driver_dialect).to have_received(:close_connection).with(conn1)
      expect(monitor_connection.get).to eq(conn2)
    end

    it 'does not close the old connection when close_old is false' do
      monitor_connection.set(conn1)
      monitor_connection.set(conn2, close_old: false)
      expect(mock_driver_dialect).not_to have_received(:close_connection).with(conn1)
    end

    it 'does not close when setting the same connection' do
      monitor_connection.set(conn1)
      monitor_connection.set(conn1)
      expect(mock_driver_dialect).not_to have_received(:close_connection).with(conn1)
    end

    it 'handles nil replacement (closes old)' do
      monitor_connection.set(conn1)
      monitor_connection.set(nil)
      expect(mock_driver_dialect).to have_received(:close_connection).with(conn1)
      expect(monitor_connection.get).to be_nil
    end

    it 'swallows errors on close via driver dialect' do
      allow(mock_driver_dialect).to receive(:close_connection).with(conn1)
      monitor_connection.set(conn1)
      expect { monitor_connection.set(conn2) }.not_to raise_error
      expect(mock_driver_dialect).to have_received(:close_connection).with(conn1)
      expect(monitor_connection.get).to eq(conn2)
    end
  end

  describe '#compare_and_set' do
    it 'succeeds when current matches expected' do
      result = monitor_connection.compare_and_set(nil, conn1)
      expect(result).to be true
      expect(monitor_connection.get).to eq(conn1)
    end

    it 'fails when current does not match expected' do
      monitor_connection.set(conn1)
      result = monitor_connection.compare_and_set(nil, conn2)
      expect(result).to be false
      expect(monitor_connection.get).to eq(conn1)
    end

    it 'uses identity comparison (equal?)' do
      # Two different objects that are == but not equal?
      obj_a = +'hello'
      obj_b = +'hello'
      monitor_connection.set(obj_a, close_old: false)
      result = monitor_connection.compare_and_set(obj_b, conn1)
      expect(result).to be false
    end

    it 'is thread-safe — only one thread wins the CAS' do
      winners = []
      threads = Array.new(10) do |i|
        Thread.new do
          winners << i if monitor_connection.compare_and_set(nil, "conn_#{i}")
        end
      end
      threads.each(&:join)
      expect(winners.size).to eq(1)
    end
  end

  describe '#close' do
    it 'closes the connection and sets to nil' do
      monitor_connection.set(conn1)
      monitor_connection.close
      expect(mock_driver_dialect).to have_received(:close_connection).with(conn1)
      expect(monitor_connection.get).to be_nil
    end

    it 'is safe to call when already nil' do
      expect { monitor_connection.close }.not_to raise_error
    end
  end

  describe '#abandon' do
    it 'abandons the connection through the driver dialect without closing it' do
      allow(mock_driver_dialect).to receive(:abandon_connection)
      monitor_connection.set(conn1)
      monitor_connection.abandon
      expect(mock_driver_dialect).to have_received(:abandon_connection).with(conn1)
      expect(mock_driver_dialect).not_to have_received(:close_connection)
    end
  end
end
