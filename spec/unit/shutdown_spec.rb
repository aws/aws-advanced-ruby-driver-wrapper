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

require 'rspec'
require 'aws_advanced_ruby_driver_wrapper'
require 'aws_advanced_ruby_driver_wrapper/monitoring/monitor'
require 'aws_advanced_ruby_driver_wrapper/services/service_utility'

RSpec.describe AwsAdvancedRubyDriverWrapper, '.shutdown' do
  let(:core) { AwsAdvancedRubyDriverWrapper::Services::CoreServices }
  let(:test_monitor_class) do
    Class.new(AwsAdvancedRubyDriverWrapper::Monitoring::Monitor) do
      def monitor
        sleep(0.01) until stopped?
      end
    end
  end

  after { core.reset! }

  it 'drains the monitor service so background monitor threads are stopped' do
    core.monitor_service.register_type(:shutdown_test_monitor, expiration_timeout_sec: 60)
    monitor = core.monitor_service.run_if_absent(:shutdown_test_monitor, 'k1', double('container')) { |_| test_monitor_class.new }
    sleep(0.05)
    expect(monitor.state).to eq(:running)

    described_class.shutdown

    expect(monitor.state).to eq(:stopped)
  end

  it 'cleans up blue/green providers' do
    expect(AwsAdvancedRubyDriverWrapper::Plugins::BlueGreen::BlueGreenPlugin).to receive(:clean_up_providers)
    described_class.shutdown
  end
end
