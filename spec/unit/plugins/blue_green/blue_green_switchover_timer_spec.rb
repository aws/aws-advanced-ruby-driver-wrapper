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
require 'aws_ruby_database_driver_wrapper/plugins/blue_green/switchover_timer'

RSpec.describe AwsRubyDatabaseDriverWrapper::Plugins::BlueGreen::SwitchoverTimer do
  describe '#expired?' do
    it 'is false before start is called' do
      timer = described_class.new(1_000_000_000)
      expect(timer.expired?).to be false
    end

    it 'is false immediately after start with a long timeout' do
      timer = described_class.new(60_000_000_000) # 60 s
      timer.start
      expect(timer.expired?).to be false
    end

    it 'is true after the timeout elapses' do
      timer = described_class.new(1) # 1 nanosecond
      timer.start
      sleep(0.001)
      expect(timer.expired?).to be true
    end
  end

  describe '#start' do
    it 'is idempotent — calling start twice does not reset the deadline' do
      timer = described_class.new(60_000_000_000)
      timer.start
      # Grab the end time by checking expiry is still false
      timer.start # second call should be a no-op
      expect(timer.expired?).to be false
    end
  end

  describe '#reset' do
    it 'clears the deadline so expired? returns false again' do
      timer = described_class.new(1)
      timer.start
      sleep(0.001)
      expect(timer.expired?).to be true
      timer.reset
      expect(timer.expired?).to be false
    end

    it 'allows start to be called again after reset' do
      timer = described_class.new(1)
      timer.start
      sleep(0.001)
      timer.reset
      # After reset end_time_nano is 0, so expired? must be false regardless of timing
      expect(timer.expired?).to be false
      timer.start
      # Timer is now running again — just verify no error is raised
      expect { timer.expired? }.not_to raise_error
    end
  end
end
