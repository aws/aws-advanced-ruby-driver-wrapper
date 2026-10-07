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
require 'aws_advanced_ruby_driver_wrapper/plugins/secrets_manager_plugin'

RSpec.describe AwsAdvancedRubyDriverWrapper, 'after fork' do
  let(:core) { AwsAdvancedRubyDriverWrapper::Services::CoreServices }
  let(:providers) { AwsAdvancedRubyDriverWrapper::Plugins::BlueGreen::BlueGreenPlugin::PROVIDERS }
  let(:pending_secret_fetches) { AwsAdvancedRubyDriverWrapper::Plugins::SecretsManagerPlugin.pending_refreshes }
  let(:test_monitor_class) do
    Class.new(AwsAdvancedRubyDriverWrapper::Monitoring::Monitor) do
      attr_reader :closed, :abandoned

      def monitor
        sleep(0.01) until stopped?
      end

      def close
        @closed = true
      end

      def abandon_connections
        @abandoned = true
      end
    end
  end

  after do
    providers.clear
    pending_secret_fetches.clear
    core.reset!
  end

  # Runs the block in a forked child and returns its (marshalled) result to the parent. A child that
  # hangs is killed after timeout_sec so the suite fails instead of stalling.
  def in_forked_child(timeout_sec: 10)
    reader, writer = IO.pipe
    pid = fork do
      reader.close
      result = begin
        yield
      rescue Exception => e # rubocop:disable Lint/RescueException
        "child raised #{e.class}: #{e.message}"
      end
      writer.write(Marshal.dump(result))
    ensure
      # Never return into RSpec from the child, or the rest of the suite would run there too.
      exit!(0)
    end
    writer.close
    unless reader.wait_readable(timeout_sec)
      Process.kill(:KILL, pid)
      Process.wait(pid)
      raise "forked child did not finish within #{timeout_sec}s"
    end
    result = reader.read
    Process.wait(pid)
    raise 'forked child exited without returning a result' if result.empty?

    Marshal.load(result) # rubocop:disable Security/MarshalLoad
  ensure
    reader&.close
  end

  def start_test_monitor
    core.monitor_service.register_type(:fork_test_monitor, expiration_timeout_sec: 60)
    monitor = core.monitor_service.run_if_absent(:fork_test_monitor, 'k1', double('container')) { |_| test_monitor_class.new }
    sleep(0.05)
    monitor
  end

  it 'starts a fresh monitor in the child instead of returning the dead inherited one' do
    inherited = start_test_monitor

    result = in_forked_child do
      fresh = core.monitor_service.run_if_absent(:fork_test_monitor, 'k1', nil) { |_| test_monitor_class.new }
      sleep(0.05)
      { same: fresh.equal?(inherited), fresh_thread_alive: fresh.instance_variable_get(:@thread)&.alive?,
        inherited_closed: inherited.closed, inherited_abandoned: inherited.abandoned }
    end

    expect(result).to eq(same: false, fresh_thread_alive: true, inherited_closed: nil, inherited_abandoned: true)
  end

  it 'leaves the parent monitor running and registered' do
    inherited = start_test_monitor

    in_forked_child { core.monitor_service.get(:fork_test_monitor, 'k1') && nil }

    expect(core.monitor_service.get(:fork_test_monitor, 'k1')).to equal(inherited)
    expect(inherited.state).to eq(:running)
    expect(inherited.closed).to be_nil
  end

  it "does not close the parent's monitors or providers when the child shuts down" do
    inherited = start_test_monitor
    provider = Struct.new(:events) do
      def stop = events << :stop
      def release_after_fork = events << :release_after_fork
    end.new([])
    providers['bgd-1'] = provider

    # The at_exit hook runs this when a forked worker exits normally.
    result = in_forked_child do
      described_class.shutdown(grace_period_sec: 1)
      { inherited_closed: inherited.closed, provider_events: provider.events }
    end

    expect(result).to eq(inherited_closed: nil, provider_events: [:release_after_fork])
  end

  it 'restarts the core background threads in the child' do
    threads = lambda do
      [core.monitor_service.instance_variable_get(:@cleanup_thread),
       core.event_publisher.instance_variable_get(:@thread),
       core.storage_service.instance_variable_get(:@cleanup_thread)]
    end

    expect(in_forked_child { threads.call.map(&:alive?) }).to eq([true, true, true])
  end

  it 'forgets inherited blue/green providers without stopping them' do
    provider_class = Struct.new(:events) do
      def stop = events << :stop
      def release_after_fork = events << :release_after_fork
    end
    provider = provider_class.new([])
    providers['bgd-1'] = provider

    result = in_forked_child { { remaining: providers.keys, events: provider.events } }

    expect(result).to eq(remaining: [], events: [:release_after_fork])
    expect(providers['bgd-1']).to equal(provider)
  end

  it 'keeps releasing and restarting in the child when releasing one inherited object raises' do
    failing = Struct.new(:name) do
      def release_after_fork = raise("release failed for #{name}")
      def stop; end
    end
    provider_class = Struct.new(:events) { def release_after_fork = events << :release_after_fork }
    good_provider = provider_class.new([])
    providers['bgd-bad'] = failing.new('provider')
    providers['bgd-good'] = good_provider
    core.monitor_service.register_type(:fork_test_monitor, expiration_timeout_sec: 60)
    core.monitor_service.run_if_absent(:fork_test_monitor, 'bad', nil) { |_| failing.new('monitor').tap { |m| def m.start; end } }
    good_monitor = start_test_monitor
    allow(described_class.logger).to receive(:warn)

    # A failure here would otherwise escape from Process._fork, so the child's own fork block would never run.
    result = in_forked_child do
      threads = [core.monitor_service.instance_variable_get(:@cleanup_thread), core.event_publisher.instance_variable_get(:@thread),
                 core.storage_service.instance_variable_get(:@cleanup_thread)]
      monitors_left = %w[bad k1].filter_map { |key| core.monitor_service.get(:fork_test_monitor, key) }
      { block_ran: true, providers_left: providers.keys, good_provider_events: good_provider.events,
        good_monitor_abandoned: good_monitor.abandoned, monitors_left: monitors_left.size, threads_alive: threads.map(&:alive?) }
    end

    expect(result).to eq(block_ran: true, providers_left: [], good_provider_events: [:release_after_fork],
                         good_monitor_abandoned: true, monitors_left: 0, threads_alive: [true, true, true])
  end

  it 'forgets Secrets Manager fetches that were in flight at fork time' do
    in_flight = Concurrent::Promises.resolvable_future
    pending_secret_fetches['secret-key'] = in_flight

    result = in_forked_child { pending_secret_fetches.keys }

    expect(result).to eq([])
    expect(pending_secret_fetches['secret-key']).to equal(in_flight)
  end

  it 'does not start extra background threads when the reset runs again in the same process' do
    result = in_forked_child do
      before = Thread.list.count(&:alive?)
      described_class.after_fork
      Thread.list.count(&:alive?) - before
    end

    expect(result).to eq(0)
  end

  it "logs instead of failing the application's fork when resetting the wrapper raises" do
    allow(described_class).to receive(:after_fork).and_raise(ThreadError, "can't create Thread")
    allow(described_class.logger).to receive(:error)

    expect(in_forked_child { :block_ran }).to eq(:block_ran)
  end
end
