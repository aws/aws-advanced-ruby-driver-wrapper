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
require 'aws_ruby_database_driver_wrapper/monitoring/monitor_connection'

RSpec.describe AwsRubyDatabaseDriverWrapper::Monitoring::MonitorConnection do
  subject(:monitor_connection) { described_class.new }

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
      expect(conn1).to have_received(:close)
      expect(monitor_connection.get).to eq(conn2)
    end

    it 'does not close the old connection when close_old is false' do
      monitor_connection.set(conn1)
      monitor_connection.set(conn2, close_old: false)
      expect(conn1).not_to have_received(:close)
    end

    it 'does not close when setting the same connection' do
      monitor_connection.set(conn1)
      monitor_connection.set(conn1)
      expect(conn1).not_to have_received(:close)
    end

    it 'handles nil replacement (closes old)' do
      monitor_connection.set(conn1)
      monitor_connection.set(nil)
      expect(conn1).to have_received(:close)
      expect(monitor_connection.get).to be_nil
    end

    it 'swallows errors on close' do
      allow(conn1).to receive(:close).and_raise(StandardError, 'close failed')
      monitor_connection.set(conn1)
      expect { monitor_connection.set(conn2) }.not_to raise_error
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
      expect(conn1).to have_received(:close)
      expect(monitor_connection.get).to be_nil
    end

    it 'is safe to call when already nil' do
      expect { monitor_connection.close }.not_to raise_error
    end
  end
end
