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
require 'aws_advanced_ruby_driver_wrapper/monitoring/cluster_topology_monitor'
require 'aws_advanced_ruby_driver_wrapper/host/host_info'
require 'aws_advanced_ruby_driver_wrapper/host/host_role'
require 'aws_advanced_ruby_driver_wrapper/host/host_availability'
require 'aws_advanced_ruby_driver_wrapper/utils/events/monitor_reset_event'
require 'aws_advanced_ruby_driver_wrapper/utils/events/batching_event_publisher'
require 'aws_advanced_ruby_driver_wrapper/utils/storage/storage_service'

RSpec.describe AwsAdvancedRubyDriverWrapper::Monitoring::ClusterTopologyMonitor do
  let(:cluster_id) { 'test-cluster' }
  let(:writer_host) do
    AwsAdvancedRubyDriverWrapper::Host::HostInfo.new(
      host: 'writer.cluster.us-east-1.rds.amazonaws.com',
      port: 5432,
      role: AwsAdvancedRubyDriverWrapper::Host::HostRole::WRITER,
      id: 'writer-instance'
    )
  end
  let(:reader_host) do
    AwsAdvancedRubyDriverWrapper::Host::HostInfo.new(
      host: 'reader.cluster.us-east-1.rds.amazonaws.com',
      port: 5432,
      role: AwsAdvancedRubyDriverWrapper::Host::HostRole::READER,
      id: 'reader-instance'
    )
  end
  let(:instance_template) do
    AwsAdvancedRubyDriverWrapper::Host::HostInfo.new(
      host: '?.cluster.us-east-1.rds.amazonaws.com',
      port: 5432
    )
  end
  let(:topology) { [writer_host, reader_host] }
  let(:mock_connection) { instance_double('Connection', close: nil) }

  let(:event_publisher) { AwsAdvancedRubyDriverWrapper::Utils::Events::BatchingEventPublisher.new(message_interval_sec: 60) }
  let(:storage_service) { AwsAdvancedRubyDriverWrapper::Utils::Storage::StorageService.new(event_publisher: event_publisher) }

  let(:db_dialect) { instance_double('DbDialect') }
  let(:driver_dialect) { instance_double('DriverDialect', close_connection: nil, apply_monitoring_defaults: nil, closed?: false) }
  let(:dialect_service) { instance_double('DialectService', db_dialect: db_dialect, driver_dialect: driver_dialect) }
  let(:connection_config) do
    instance_double('ConnectionConfig', wrapper_props: {
                      cluster_topology_refresh_rate_ms: 100,
                      cluster_topology_high_refresh_rate_ms: 50,
                      cluster_topology_max_instance_monitors: 16
                    }, initial_host_info: instance_template)
  end
  let(:connection_service) do
    instance_double('ConnectionService', config: connection_config, wrapper_props: connection_config.wrapper_props,
                                         initial_host_info: instance_template)
  end
  let(:plugin_manager) { instance_double('PluginManager') }
  let(:service_container) do
    AwsAdvancedRubyDriverWrapper::Services::ServiceContainer.new(
      event_publisher: event_publisher,
      storage_service: storage_service,
      dialect_service: dialect_service,
      connection_service: connection_service,
      plugin_manager: plugin_manager
    )
  end

  let(:topology_utils) { instance_double('TopologyUtils') }

  subject(:monitor) do
    described_class.new(
      service_container: service_container,
      cluster_id: cluster_id,
      instance_template: instance_template,
      topology_utils: topology_utils,
      monitoring_driver_props: { host: 'localhost', port: 5432 },
      monitoring_wrapper_props: {}
    )
  end

  before do
    storage_service.register(:topology, ttl: 300)
    allow(topology_utils).to receive(:query_topology) { [writer_host, reader_host] }
    allow(topology_utils).to receive(:writer_instance?).and_return(true)
    allow(db_dialect).to receive(:host_role).and_return(AwsAdvancedRubyDriverWrapper::Host::HostRole::WRITER)
    allow(plugin_manager).to receive(:internal_connect).and_return(mock_connection)
  end

  after do
    monitor.stop if monitor.state == :running
    event_publisher.release_resources
    storage_service.shutdown
  end

  describe '#initialize' do
    it 'starts in panic mode (no verified writer)' do
      expect(monitor.send(:panic_mode?)).to be true
    end

    it 'stores the cluster_id' do
      expect(monitor.instance_variable_get(:@cluster_id)).to eq(cluster_id)
    end
  end

  describe '#force_refresh' do
    context 'when topology is updated within timeout' do
      it 'returns updated topology after monitor refreshes' do
        # Start monitor — it will enter panic mode, find the writer, and update the cache.
        # Since cache starts empty (nil), any write is a new reference.
        monitor.start
        sleep(0.05)

        result = monitor.force_refresh(false, 2.0)
        expect(result).not_to be_nil
        expect(result).to be_a(Array)
      end
    end

    context 'when verify_writer is true' do
      it 'clears the monitoring connection to trigger panic mode' do
        # Start monitor and let it establish a writer connection
        monitor.start
        sleep(0.3)

        # Now force_refresh with verify_writer — it nils the connection, re-enters panic,
        # finds the writer again, and writes a new topology object to the cache.
        result = monitor.force_refresh(true, 2.0)
        expect(result).not_to be_nil
      end
    end

    context 'when timeout expires' do
      it 'raises Timeout::Error' do
        # Don't start the monitor so no updates happen
        allow(topology_utils).to receive(:query_topology).and_return(nil)
        storage_service.set(:topology, cluster_id, topology)

        expect { monitor.force_refresh(false, 0.05) }.to raise_error(Timeout::Error)
      end
    end

    context 'when timeout_sec is 0' do
      it 'returns current hosts immediately' do
        storage_service.set(:topology, cluster_id, topology)
        result = monitor.force_refresh(false, 0)
        expect(result).to eq(topology)
      end
    end

    # These exercise wait_for_topology_update directly (force_refresh delegates to it). force_refresh resets
    # @verified_writer to false and relies on the running monitor thread to re-verify the writer, so we set up the
    # verified-writer state and drive the wait loop directly to keep the tests deterministic.
    context 'when verify_writer is true and the cached writer is stale' do
      let(:new_writer_host) do
        AwsAdvancedRubyDriverWrapper::Host::HostInfo.new(
          host: 'new-writer.cluster.us-east-1.rds.amazonaws.com',
          port: 5432,
          role: AwsAdvancedRubyDriverWrapper::Host::HostRole::WRITER,
          id: 'new-writer-instance'
        )
      end

      it 'keeps waiting until the cached writer matches the verified writer' do
        # The monitor has verified the new writer directly, but the cache still reports the old writer.
        monitor.instance_variable_set(:@verified_writer, true)
        monitor.instance_variable_set(:@writer_info, new_writer_host)
        storage_service.set(:topology, cluster_id, [writer_host, reader_host])

        # A background writer updates the cache with the correct writer partway through the wait.
        updater = Thread.new do
          sleep(0.1)
          monitor.send(:update_topology_cache, [new_writer_host, reader_host])
        end

        result = monitor.send(:wait_for_topology_update, 2.0, true)
        updater.join
        expect(result.find { |h| h.role == AwsAdvancedRubyDriverWrapper::Host::HostRole::WRITER }.host)
          .to eq(new_writer_host.host)
      end

      it 'raises Timeout::Error when the cached writer never matches the verified writer' do
        monitor.instance_variable_set(:@verified_writer, true)
        monitor.instance_variable_set(:@writer_info, new_writer_host)
        storage_service.set(:topology, cluster_id, [writer_host, reader_host])

        # A new cache entry arrives, but the writer is still stale, so waiting must continue until timeout.
        updater = Thread.new do
          sleep(0.05)
          monitor.send(:update_topology_cache, [writer_host.deep_dup, reader_host])
        end

        expect { monitor.send(:wait_for_topology_update, 0.2, true) }.to raise_error(Timeout::Error)
        updater.join
      end

      it 'does not wait on a matching writer when verify_writer is false' do
        # Even though the cached writer is stale, a plain refresh returns as soon as a new entry is cached.
        monitor.instance_variable_set(:@verified_writer, true)
        monitor.instance_variable_set(:@writer_info, new_writer_host)
        storage_service.set(:topology, cluster_id, [writer_host, reader_host])

        updater = Thread.new do
          sleep(0.05)
          monitor.send(:update_topology_cache, [writer_host.deep_dup, reader_host])
        end

        result = monitor.send(:wait_for_topology_update, 2.0, false)
        updater.join
        expect(result.find { |h| h.role == AwsAdvancedRubyDriverWrapper::Host::HostRole::WRITER }.host)
          .to eq(writer_host.host)
      end
    end
  end

  describe 'regular mode' do
    it 'periodically fetches topology and updates cache' do
      # Set up a verified writer connection so monitor is in regular mode
      monitor.instance_variable_get(:@monitoring_connection).set(mock_connection, close_old: false)
      monitor.instance_variable_set(:@verified_writer, true)
      monitor.instance_variable_set(:@writer_info, writer_host)

      monitor.start
      sleep(0.3) # Let a few cycles run

      expect(topology_utils).to have_received(:query_topology).at_least(:once)
      cached = storage_service.get(:topology, cluster_id)
      expect(cached).to eq(topology)
    end

    it 'enters panic mode when topology fetch fails' do
      monitor.instance_variable_get(:@monitoring_connection).set(mock_connection, close_old: false)
      monitor.instance_variable_set(:@verified_writer, true)

      allow(topology_utils).to receive(:query_topology).and_return(nil)

      monitor.start
      sleep(0.2)

      expect(monitor.send(:panic_mode?)).to be true
    end
  end

  describe 'panic mode' do
    it 'spawns host worker threads to find the writer' do
      monitor.start
      sleep(0.3)

      # The monitor should have attempted to connect and find the writer
      expect(db_dialect).to have_received(:host_role).at_least(:once)
    end

    it 'exits panic mode when writer is found' do
      monitor.start
      sleep(0.5)

      # With our mocks returning WRITER, the monitor should exit panic mode
      expect(monitor.send(:panic_mode?)).to be false
    end

    it 'caps host threads at max_host_threads' do
      many_hosts = Array.new(20) do |i|
        AwsAdvancedRubyDriverWrapper::Host::HostInfo.new(
          host: "host-#{i}.cluster.us-east-1.rds.amazonaws.com",
          port: 5432,
          role: AwsAdvancedRubyDriverWrapper::Host::HostRole::READER,
          id: "instance-#{i}"
        )
      end
      allow(topology_utils).to receive(:query_topology).and_return(many_hosts)
      # Make host_role slow so threads stay alive
      allow(db_dialect).to receive(:host_role) do
        sleep(0.5)
        AwsAdvancedRubyDriverWrapper::Host::HostRole::READER
      end

      monitor.start
      sleep(0.3)

      submitted = monitor.instance_variable_get(:@instance_monitors)
      expect(submitted.size).to be <= 16
    end
  end

  describe '#process_event' do
    it 'resets state when receiving MonitorResetEvent for this cluster' do
      monitor.instance_variable_get(:@monitoring_connection).set(mock_connection, close_old: false)
      monitor.instance_variable_set(:@verified_writer, true)

      event = AwsAdvancedRubyDriverWrapper::Utils::Events::MonitorResetEvent.new(
        cluster_id: cluster_id,
        endpoints: Set[instance_template.host]
      )
      monitor.process_event(event)

      expect(monitor.send(:panic_mode?)).to be true
    end

    it 'ignores events for other clusters' do
      monitor.instance_variable_get(:@monitoring_connection).set(mock_connection, close_old: false)
      monitor.instance_variable_set(:@verified_writer, true)

      event = AwsAdvancedRubyDriverWrapper::Utils::Events::MonitorResetEvent.new(
        cluster_id: 'other-cluster',
        endpoints: Set[instance_template.host]
      )
      monitor.process_event(event)

      expect(monitor.send(:panic_mode?)).to be false
    end
  end

  describe '#close' do
    it 'closes all connections' do
      conn1 = instance_double('Connection', close: nil)
      conn2 = instance_double('Connection', close: nil)
      monitor.instance_variable_get(:@monitoring_connection).set(conn1, close_old: false)
      monitor.instance_variable_get(:@instance_monitors_writer_conn).set(conn2, close_old: false)

      monitor.close

      expect(driver_dialect).to have_received(:close_connection).with(conn1)
      expect(driver_dialect).to have_received(:close_connection).with(conn2)
    end
  end

  describe 'stable reader topologies' do
    it 'accepts topology when all readers agree for the required duration' do
      # Simulate reader topologies being stored
      monitor.instance_variable_set(:@instance_monitor_topologies, {
                                      'reader-1' => topology,
                                      'reader-2' => topology
                                    })
      monitor.instance_variable_set(:@completed_one_cycle, {
                                      'writer-instance' => true,
                                      'reader-instance' => true,
                                      'reader-1' => true,
                                      'reader-2' => true
                                    })

      # Pre-populate stored hosts so the check has something to work with
      storage_service.set(:topology, cluster_id, topology)

      # First call starts the timer
      monitor.send(:check_stable_instance_monitor_topologies)
      expect(monitor.instance_variable_get(:@stable_start_time)).to be > 0

      # Simulate time passing beyond the stable duration
      monitor.instance_variable_set(
        :@stable_start_time,
        Process.clock_gettime(Process::CLOCK_MONOTONIC) - described_class::STABLE_TOPOLOGIES_DURATION_SEC - 1
      )

      monitor.send(:check_stable_instance_monitor_topologies)

      # Timer should be reset after accepting
      expect(monitor.instance_variable_get(:@stable_start_time)).to eq(0)
    end

    it 'accepts topology when cluster has more hosts than max_instance_monitors' do
      # Simulate a cluster with 20 hosts but max_instance_monitors is 16 (default)
      extra_hosts = (1..20).map do |i|
        AwsAdvancedRubyDriverWrapper::Host::HostInfo.new(
          host: "host-#{i}.cluster.us-east-1.rds.amazonaws.com", port: 5432,
          role: i == 1 ? AwsAdvancedRubyDriverWrapper::Host::HostRole::WRITER : AwsAdvancedRubyDriverWrapper::Host::HostRole::READER,
          id: "host-#{i}"
        )
      end
      storage_service.set(:topology, cluster_id, extra_hosts)

      # Only the first 16 have completed (matching max_instance_monitors)
      completed = extra_hosts.first(16).to_h { |h| [h.id, true] }
      monitor.instance_variable_set(:@completed_one_cycle, completed)

      # All monitored readers report the same topology
      reader_topos = extra_hosts.first(16).reject { |h| h.role == AwsAdvancedRubyDriverWrapper::Host::HostRole::WRITER }
                                          .to_h { |h| [h.id, extra_hosts] }
      monitor.instance_variable_set(:@instance_monitor_topologies, reader_topos)

      # First call starts the timer
      monitor.send(:check_stable_instance_monitor_topologies)
      expect(monitor.instance_variable_get(:@stable_start_time)).to be > 0
    end

    it 'resets timer when topologies disagree' do
      topo_a = [writer_host, reader_host]
      topo_b = [writer_host] # Different

      monitor.instance_variable_set(:@instance_monitor_topologies, {
                                      'reader-1' => topo_a,
                                      'reader-2' => topo_b
                                    })
      monitor.instance_variable_set(:@completed_one_cycle, {
                                      'writer-instance' => true,
                                      'reader-instance' => true,
                                      'reader-1' => true,
                                      'reader-2' => true
                                    })
      monitor.instance_variable_set(:@stable_start_time, 12_345.0)
      storage_service.set(:topology, cluster_id, topology)

      monitor.send(:check_stable_instance_monitor_topologies)
      expect(monitor.instance_variable_get(:@stable_start_time)).to eq(0)
    end
  end

  describe 'backoff calculation' do
    it 'increases with attempts' do
      b0 = monitor.send(:calculate_backoff, 0)
      b3 = monitor.send(:calculate_backoff, 3)
      b6 = monitor.send(:calculate_backoff, 6)

      expect(b3).to be > b0
      expect(b6).to be > b3
    end

    it 'caps at MAX_BACKOFF_MS' do
      result = monitor.send(:calculate_backoff, 100)
      expect(result).to be <= described_class::MAX_BACKOFF_SEC
    end
  end
end
