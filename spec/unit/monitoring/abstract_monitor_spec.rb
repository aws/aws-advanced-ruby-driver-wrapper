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
require 'aws_ruby_database_driver_wrapper/monitoring/abstract_monitor'

RSpec.describe AwsRubyDatabaseDriverWrapper::Monitoring::AbstractMonitor do
  let(:monitor_class) do
    Class.new(described_class) do
      attr_accessor :iterations

      def initialize(**opts)
        super
        @iterations = 0
      end

      def monitor
        until stopped?
          @iterations += 1
          update_activity
          sleep(0.01)
        end
      end
    end
  end

  let(:error_monitor_class) do
    Class.new(described_class) do
      def monitor
        raise 'boom'
      end
    end
  end

  after do
    @monitor&.stop if @monitor&.state == :running
  end

  describe '#start' do
    it 'spawns a thread and sets state to running' do
      @monitor = monitor_class.new(termination_timeout_sec: 2)
      @monitor.start
      sleep(0.05)
      expect(@monitor.state).to eq(:running)
    end

    it 'stays running when start is called again' do
      @monitor = monitor_class.new(termination_timeout_sec: 2)
      @monitor.start
      @monitor.start
      sleep(0.05)
      expect(@monitor.state).to eq(:running)
    end
  end

  describe '#stop' do
    it 'signals stop, joins thread, sets state to stopped' do
      @monitor = monitor_class.new(termination_timeout_sec: 2)
      @monitor.start
      sleep(0.05)
      @monitor.stop
      expect(@monitor.state).to eq(:stopped)
    end

    it 'kills thread if it does not terminate within timeout' do
      stuck_class = Class.new(described_class) do
        def monitor
          sleep(999) until stopped?
        end
      end
      @monitor = stuck_class.new(termination_timeout_sec: 0.05)
      @monitor.start
      sleep(0.02)
      @monitor.stop
      expect(@monitor.state).to eq(:stopped)
    end
  end

  describe 'error handling' do
    it 'sets state to error on unhandled exception' do
      @monitor = error_monitor_class.new(termination_timeout_sec: 2)
      @monitor.start
      sleep(0.05)
      expect(@monitor.state).to eq(:error)
    end
  end

  describe '#last_activity_nanos' do
    it 'updates during run' do
      @monitor = monitor_class.new(termination_timeout_sec: 2)
      initial = @monitor.last_activity_nanos
      @monitor.start
      sleep(0.05)
      expect(@monitor.last_activity_nanos).to be > initial
    end
  end
end
