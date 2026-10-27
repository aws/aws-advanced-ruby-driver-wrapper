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
require 'aws_advanced_ruby_driver_wrapper/plugins/blue_green/status_provider'
require 'aws_advanced_ruby_driver_wrapper/plugins/blue_green/status'
require 'aws_advanced_ruby_driver_wrapper/plugins/blue_green/phase'
require 'aws_advanced_ruby_driver_wrapper/plugins/blue_green/role'
require 'aws_advanced_ruby_driver_wrapper/services/service_container'
require 'aws_advanced_ruby_driver_wrapper/host/host_info'
require 'aws_advanced_ruby_driver_wrapper/host/host_role'
require 'concurrent'

RSpec.describe AwsAdvancedRubyDriverWrapper::Plugins::BlueGreen::StatusProvider, :blue_green do
  let(:bg)    { AwsAdvancedRubyDriverWrapper::Plugins::BlueGreen }
  let(:phase) { bg::Phase }
  let(:role)  { bg::Role }

  let(:bgd_id)     { 'bgd-test-001' }
  let(:cluster_id) { 'cluster-test-001' }

  let(:blue_writer_host)  { 'blue-instance-1.cluster-abc.us-east-1.rds.amazonaws.com' }
  let(:blue_reader_host)  { 'blue-instance-2.cluster-abc.us-east-1.rds.amazonaws.com' }
  let(:blue_cluster_ep)   { 'blue.cluster-abc.us-east-1.rds.amazonaws.com' }
  let(:blue_cluster_ro)   { 'blue.cluster-ro-abc.us-east-1.rds.amazonaws.com' }
  let(:green_writer_host) { 'blue-instance-1-green-xyz.cluster-abc.us-east-1.rds.amazonaws.com' }
  let(:green_reader_host) { 'blue-instance-2-green-xyz.cluster-abc.us-east-1.rds.amazonaws.com' }
  let(:green_cluster_ep)  { 'blue-green-xyz.cluster-abc.us-east-1.rds.amazonaws.com' }
  let(:green_cluster_ro)  { 'blue-green-xyz.cluster-ro-abc.us-east-1.rds.amazonaws.com' }

  let(:storage_service) { double('storage_service', get: nil, set: nil, remove: nil) }
  let(:host_service)    { double('host_service') }
  let(:event_publisher) { double('event_publisher', publish: nil) }
  let(:db_dialect)      { double('db_dialect', blue_green_status_available?: true, create_host_list_provider: nil) }
  let(:driver_dialect)  { double('driver_dialect') }
  let(:dialect_service) { double('dialect_service', db_dialect: db_dialect, driver_dialect: driver_dialect) }
  let(:initial_host)    { host_info(blue_writer_host) }
  let(:connection_service) do
    double('connection_service',
           current_host_info: initial_host,
           driver_props: Concurrent::Map.new,
           prefixed_wrapper_config: {},
           prefixed_driver_config: {},
           pg?: false,
           config: double('config',
                          dup: double('config_dup', initial_host_info: nil, 'initial_host_info=': nil, wrapper_props: {},
                                                    'wrapper_props=': nil)))
  end
  let(:plugin_manager) { double('plugin_manager', plugin_in_use?: false, iam_token_plugin_in_use?: false) }
  let(:service_container) do
    AwsAdvancedRubyDriverWrapper::Services::ServiceContainer.new(
      connection_service, dialect_service, event_publisher,
      host_service, plugin_manager, nil, storage_service, nil
    )
  end
  let(:props) { Concurrent::Map.new }

  subject(:provider) do
    # Prevent background monitor threads from starting
    allow_any_instance_of(described_class).to receive(:init_monitoring)
    described_class.new(service_container, props, bgd_id, cluster_id)
  end

  # Shared topology used across multiple tests
  let(:blue_topology) do
    [host_info(blue_writer_host, role: AwsAdvancedRubyDriverWrapper::Host::HostRole::WRITER),
     host_info(blue_reader_host, role: AwsAdvancedRubyDriverWrapper::Host::HostRole::READER)]
  end
  let(:green_topology) do
    [host_info(green_writer_host, role: AwsAdvancedRubyDriverWrapper::Host::HostRole::WRITER),
     host_info(green_reader_host, role: AwsAdvancedRubyDriverWrapper::Host::HostRole::READER)]
  end
  let(:blue_ip_map)  { { blue_writer_host => '10.0.0.1', blue_reader_host => '10.0.0.2' } }
  let(:green_ip_map) { { green_writer_host => '10.0.1.1', green_reader_host => '10.0.1.2' } }

  def source_status(phase:, **opts)
    build_interim_status(phase: phase, start_topology: blue_topology,
                         host_names: [blue_writer_host, blue_reader_host, blue_cluster_ep, blue_cluster_ro], **opts)
  end

  def target_status(phase:, **opts)
    build_interim_status(phase: phase, start_topology: green_topology,
                         host_names: [green_writer_host, green_reader_host, green_cluster_ep, green_cluster_ro], **opts)
  end

  describe '#prepare_status' do
    context 'NOT_CREATED phase' do
      it 'produces a NOT_CREATED summary status' do
        provider.prepare_status(role::SOURCE, source_status(phase: phase::NOT_CREATED))
        status = provider.instance_variable_get(:@summary_status)
        expect(status.current_phase).to eq(phase::NOT_CREATED)
      end
    end

    context 'CREATED phase' do
      it 'produces a CREATED summary status with no routing' do
        provider.prepare_status(role::SOURCE, source_status(phase: phase::CREATED, start_ip_addresses_by_host: blue_ip_map))
        provider.prepare_status(role::TARGET, target_status(phase: phase::CREATED, start_ip_addresses_by_host: green_ip_map))

        status = provider.instance_variable_get(:@summary_status)
        expect(status.current_phase).to eq(phase::CREATED)
        expect(status.connect_routing).to be_empty
        expect(status.execute_routing).to be_empty
      end

      it 'registers source hosts as SOURCE role' do
        provider.prepare_status(role::SOURCE, source_status(phase: phase::CREATED, start_ip_addresses_by_host: blue_ip_map))
        status = provider.instance_variable_get(:@summary_status)
        expect(status.role_by_host[blue_writer_host]).to eq(role::SOURCE)
      end
    end

    context 'PREPARATION phase' do
      before do
        provider.prepare_status(role::SOURCE, source_status(phase: phase::CREATED, start_ip_addresses_by_host: blue_ip_map))
        provider.prepare_status(role::TARGET, target_status(phase: phase::CREATED, start_ip_addresses_by_host: green_ip_map))
      end

      it 'produces a PREPARATION summary status' do
        provider.prepare_status(role::SOURCE, source_status(phase: phase::PREPARATION, start_ip_addresses_by_host: blue_ip_map))
        status = provider.instance_variable_get(:@summary_status)
        expect(status.current_phase).to eq(phase::PREPARATION)
      end

      it 'adds substitute connect routing for blue hosts' do
        provider.prepare_status(role::SOURCE, source_status(phase: phase::PREPARATION, start_ip_addresses_by_host: blue_ip_map))
        status = provider.instance_variable_get(:@summary_status)
        expect(status.connect_routing).not_to be_empty
        expect(status.execute_routing).to be_empty
      end
    end

    context 'IN_PROGRESS phase' do
      before do
        provider.prepare_status(role::SOURCE, source_status(phase: phase::CREATED, start_ip_addresses_by_host: blue_ip_map))
        provider.prepare_status(role::TARGET, target_status(phase: phase::CREATED, start_ip_addresses_by_host: green_ip_map))
        provider.prepare_status(role::SOURCE, source_status(phase: phase::PREPARATION, start_ip_addresses_by_host: blue_ip_map))
        allow(event_publisher).to receive(:publish)
      end

      it 'produces an IN_PROGRESS summary status' do
        provider.prepare_status(role::SOURCE, source_status(phase: phase::IN_PROGRESS, start_ip_addresses_by_host: blue_ip_map))
        status = provider.instance_variable_get(:@summary_status)
        expect(status.current_phase).to eq(phase::IN_PROGRESS)
      end

      it 'suspends both connect and execute routing for source and target' do
        provider.prepare_status(role::SOURCE, source_status(phase: phase::IN_PROGRESS, start_ip_addresses_by_host: blue_ip_map))
        status = provider.instance_variable_get(:@summary_status)
        expect(status.connect_routing).not_to be_empty
        expect(status.execute_routing).not_to be_empty
      end
    end

    context 'POST phase' do
      before do
        provider.prepare_status(role::SOURCE, source_status(phase: phase::CREATED, start_ip_addresses_by_host: blue_ip_map))
        provider.prepare_status(role::TARGET, target_status(phase: phase::CREATED, start_ip_addresses_by_host: green_ip_map))
        provider.prepare_status(role::SOURCE, source_status(phase: phase::PREPARATION, start_ip_addresses_by_host: blue_ip_map))
        allow(event_publisher).to receive(:publish)
        provider.prepare_status(role::SOURCE, source_status(phase: phase::IN_PROGRESS, start_ip_addresses_by_host: blue_ip_map))
      end

      it 'produces a POST summary status' do
        provider.prepare_status(role::SOURCE, source_status(phase: phase::POST, start_ip_addresses_by_host: blue_ip_map))
        status = provider.instance_variable_get(:@summary_status)
        expect(status.current_phase).to eq(phase::POST)
      end

      it 'has no execute routing in POST' do
        provider.prepare_status(role::SOURCE, source_status(phase: phase::POST, start_ip_addresses_by_host: blue_ip_map))
        status = provider.instance_variable_get(:@summary_status)
        expect(status.execute_routing).to be_empty
      end
    end

    context 'COMPLETED phase' do
      # Capture the last status written to storage before reset_context_when_completed clears it.
      let(:captured_statuses) { [] }

      before do
        allow(storage_service).to receive(:set) do |_ns, _key, s|
          captured_statuses << s if s.is_a?(bg::Status)
        end

        provider.prepare_status(role::SOURCE, source_status(phase: phase::CREATED, start_ip_addresses_by_host: blue_ip_map))
        provider.prepare_status(role::TARGET, target_status(phase: phase::CREATED, start_ip_addresses_by_host: green_ip_map))
        provider.prepare_status(role::SOURCE, source_status(phase: phase::PREPARATION, start_ip_addresses_by_host: blue_ip_map))
        allow(event_publisher).to receive(:publish)
        provider.prepare_status(role::SOURCE, source_status(phase: phase::IN_PROGRESS, start_ip_addresses_by_host: blue_ip_map))
        provider.prepare_status(role::SOURCE, source_status(phase: phase::POST, start_ip_addresses_by_host: blue_ip_map))
      end

      it 'produces a COMPLETED summary status when DNS flags are set' do
        provider.prepare_status(
          role::SOURCE,
          source_status(phase: phase::COMPLETED, start_ip_addresses_by_host: blue_ip_map, all_start_topology_ip_changed: true)
        )
        provider.prepare_status(
          role::TARGET,
          target_status(phase: phase::COMPLETED, start_ip_addresses_by_host: green_ip_map,
                        all_start_topology_endpoints_removed: true, all_topology_changed: true)
        )

        # reset_context_when_completed clears @summary_status after the final update;
        # read the last status that was written to the storage cache instead.
        completed_status = captured_statuses.find { |s| s.current_phase == phase::COMPLETED }
        expect(completed_status).not_to be_nil
        expect(completed_status.connect_routing).to be_empty
        expect(completed_status.execute_routing).to be_empty
      end

      it 'clears corresponding_hosts once DNS is fully settled' do
        provider.prepare_status(
          role::SOURCE,
          source_status(phase: phase::COMPLETED, start_ip_addresses_by_host: blue_ip_map, all_start_topology_ip_changed: true)
        )
        provider.prepare_status(
          role::TARGET,
          target_status(phase: phase::COMPLETED, start_ip_addresses_by_host: green_ip_map,
                        all_start_topology_endpoints_removed: true, all_topology_changed: true)
        )

        completed_status = captured_statuses.find { |s| s.current_phase == phase::COMPLETED }
        expect(completed_status.corresponding_hosts).to be_empty
      end
    end

    context 'rollback detection' do
      before do
        provider.prepare_status(role::SOURCE, source_status(phase: phase::CREATED, start_ip_addresses_by_host: blue_ip_map))
        provider.prepare_status(role::TARGET, target_status(phase: phase::CREATED, start_ip_addresses_by_host: green_ip_map))
        provider.prepare_status(role::SOURCE, source_status(phase: phase::PREPARATION, start_ip_addresses_by_host: blue_ip_map))
        allow(event_publisher).to receive(:publish)
        provider.prepare_status(role::SOURCE, source_status(phase: phase::IN_PROGRESS, start_ip_addresses_by_host: blue_ip_map))
        # Target must have previously reported IN_PROGRESS so a regression to CREATED is detectable
        provider.prepare_status(role::TARGET, target_status(phase: phase::IN_PROGRESS, start_ip_addresses_by_host: green_ip_map))
      end

      it 'sets rollback flag when target phase regresses' do
        # Spy on the rollback flag at the moment the regressed status is processed,
        # before reset_context_when_completed clears it.
        rollback_observed = false
        allow(storage_service).to receive(:set) do
          rollback_observed = provider.instance_variable_get(:@rollback)
        end

        regressed = build_interim_status(
          phase: phase::CREATED,
          start_topology: green_topology,
          start_ip_addresses_by_host: green_ip_map,
          host_names: [green_writer_host, green_reader_host, green_cluster_ep, green_cluster_ro, 'extra.host.example.com']
        )
        provider.prepare_status(role::TARGET, regressed)
        expect(rollback_observed).to be true
      end
    end

    context 'idempotency' do
      it 'does not re-process an identical interim status' do
        status = source_status(phase: phase::CREATED, start_ip_addresses_by_host: blue_ip_map)
        provider.prepare_status(role::SOURCE, status)
        first_summary = provider.instance_variable_get(:@summary_status)

        expect(storage_service).not_to receive(:set)
        provider.prepare_status(role::SOURCE, status)
        expect(provider.instance_variable_get(:@summary_status)).to equal(first_summary)
      end
    end

    context 'drop-blue-connections marker' do
      let(:store)      { {} }
      let(:marker_key) { bg::BlueGreenPlugin.drop_marker_key(bgd_id) }

      def markers
        store.values.grep(bg::DropBlueConnectionsMarker)
      end

      def current_marker
        store[marker_key]
      end

      before do
        # A stateful storage stub so an activation can read back the pending marker it stored.
        allow(storage_service).to receive(:set) { |_ns, key, value| store[key] = value }
        allow(storage_service).to receive(:get) { |_ns, key, **| store[key] }
        allow(storage_service).to receive(:remove) { |_ns, key| store.delete(key) }
        allow(event_publisher).to receive(:publish)

        provider.prepare_status(role::SOURCE, source_status(phase: phase::CREATED, start_ip_addresses_by_host: blue_ip_map))
        provider.prepare_status(role::TARGET, target_status(phase: phase::CREATED, start_ip_addresses_by_host: green_ip_map))
        provider.prepare_status(role::SOURCE, source_status(phase: phase::PREPARATION, start_ip_addresses_by_host: blue_ip_map))
      end

      it 'creates a pending marker covering the blue hosts and their IPs at IN_PROGRESS' do
        provider.prepare_status(role::SOURCE, source_status(phase: phase::IN_PROGRESS, start_ip_addresses_by_host: blue_ip_map))

        marker = current_marker
        expect(marker).to be_a(bg::DropBlueConnectionsMarker)
        expect(marker.active?).to be(false)
        expect(marker.blue_hosts).to include(blue_writer_host, blue_reader_host, '10.0.0.1', '10.0.0.2')
      end

      it 'activates the marker at POST, keeping its identity' do
        provider.prepare_status(role::SOURCE, source_status(phase: phase::IN_PROGRESS, start_ip_addresses_by_host: blue_ip_map))
        pending_id = current_marker.id

        provider.prepare_status(role::SOURCE, source_status(phase: phase::POST, start_ip_addresses_by_host: blue_ip_map))

        expect(current_marker.active?).to be(true)
        expect(current_marker.id).to eq(pending_id)
      end

      it 'keeps the active marker after a completed switchover resets context' do
        provider.prepare_status(role::SOURCE, source_status(phase: phase::IN_PROGRESS, start_ip_addresses_by_host: blue_ip_map))
        provider.prepare_status(role::SOURCE, source_status(phase: phase::POST, start_ip_addresses_by_host: blue_ip_map))
        provider.prepare_status(
          role::SOURCE,
          source_status(phase: phase::COMPLETED, start_ip_addresses_by_host: blue_ip_map, all_start_topology_ip_changed: true)
        )
        provider.prepare_status(
          role::TARGET,
          target_status(phase: phase::COMPLETED, start_ip_addresses_by_host: green_ip_map,
                        all_start_topology_endpoints_removed: true, all_topology_changed: true)
        )

        expect(current_marker).to be_a(bg::DropBlueConnectionsMarker)
        expect(current_marker.active?).to be(true)
      end

      it 'discards the marker on rollback' do
        provider.prepare_status(role::SOURCE, source_status(phase: phase::IN_PROGRESS, start_ip_addresses_by_host: blue_ip_map))
        provider.prepare_status(role::TARGET, target_status(phase: phase::IN_PROGRESS, start_ip_addresses_by_host: green_ip_map))
        expect(current_marker).to be_a(bg::DropBlueConnectionsMarker)

        # Target regresses to CREATED -> rollback -> context reset discards the marker.
        provider.prepare_status(role::TARGET, target_status(phase: phase::CREATED, start_ip_addresses_by_host: green_ip_map))

        expect(current_marker).to be_nil
      end

      it 'does not create a marker at POST if it never saw IN_PROGRESS (started mid-switchover)' do
        # Jump straight to POST without an IN_PROGRESS observation, as if the provider began watching
        # the deployment after it was already past IN_PROGRESS. It has no reliable switchover time, so
        # it cannot tell which connections predate the switchover and must invalidate nothing.
        provider.prepare_status(role::SOURCE, source_status(phase: phase::POST, start_ip_addresses_by_host: blue_ip_map))

        expect(markers).to be_empty
      end

      it 'does not create a marker at COMPLETED if it never saw IN_PROGRESS (started while already COMPLETED)' do
        # A deployment stays in SWITCHOVER_COMPLETED until it is deleted, so a process that starts then
        # sees COMPLETED as its first status. Creating a marker with "now" would invalidate every
        # connection this process opened before now — including connections opened to green after the
        # switchover — and would repeat each time the marker's TTL lapses and COMPLETED is re-processed.
        provider.prepare_status(role::SOURCE, source_status(phase: phase::COMPLETED, start_ip_addresses_by_host: blue_ip_map))

        expect(markers).to be_empty
      end

      it 'activates the marker before publishing the POST status' do
        # The held-call re-check in BlueGreenPlugin#execute relies on this ordering: the marker must be
        # active by the time the POST status is published and wakes calls held in SuspendExecuteRouting,
        # or a released call could re-check against a still-pending marker and run on retired blue.
        marker_active_when_post_published = nil
        allow(storage_service).to receive(:set) do |ns, key, value|
          if ns == bg::BlueGreenPlugin::BLUE_GREEN_NAME && value.respond_to?(:current_phase) && value.current_phase == phase::POST
            marker_active_when_post_published = store[marker_key]&.active?
          end
          store[key] = value
        end

        provider.prepare_status(role::SOURCE, source_status(phase: phase::IN_PROGRESS, start_ip_addresses_by_host: blue_ip_map))
        provider.prepare_status(role::SOURCE, source_status(phase: phase::POST, start_ip_addresses_by_host: blue_ip_map))

        expect(marker_active_when_post_published).to be(true)
      end

      it 'stores the marker in the long-lived drop-marker partition, not the status partition' do
        marker_namespaces = []
        allow(storage_service).to receive(:set) do |ns, key, value|
          marker_namespaces << ns if value.is_a?(bg::DropBlueConnectionsMarker)
          store[key] = value
        end

        provider.prepare_status(role::SOURCE, source_status(phase: phase::IN_PROGRESS, start_ip_addresses_by_host: blue_ip_map))

        expect(marker_namespaces).not_to be_empty
        expect(marker_namespaces).to all(eq(bg::BlueGreenPlugin::DROP_MARKER_NAME))
        expect(marker_namespaces).not_to include(bg::BlueGreenPlugin::BLUE_GREEN_NAME)
      end

      context 'when the switchover timer expires' do
        it 'does not create a marker when it times out in PREPARATION' do
          # The before block leaves the provider at PREPARATION. Re-sending the identical status runs
          # only the timer-expiry check.
          allow_any_instance_of(bg::SwitchoverTimer).to receive(:expired?).and_return(true)
          provider.prepare_status(role::SOURCE, source_status(phase: phase::PREPARATION, start_ip_addresses_by_host: blue_ip_map))

          expect(markers).to be_empty
        end

        it 'does not activate the pending marker when it times out in IN_PROGRESS' do
          provider.prepare_status(role::SOURCE, source_status(phase: phase::IN_PROGRESS, start_ip_addresses_by_host: blue_ip_map))
          expect(current_marker.active?).to be(false)

          allow_any_instance_of(bg::SwitchoverTimer).to receive(:expired?).and_return(true)
          provider.prepare_status(role::SOURCE, source_status(phase: phase::IN_PROGRESS, start_ip_addresses_by_host: blue_ip_map))

          # A timeout in IN_PROGRESS could still roll back, so the marker must stay pending.
          expect(current_marker.active?).to be(false)
        end

        it 'keeps the marker active when it times out in POST' do
          provider.prepare_status(role::SOURCE, source_status(phase: phase::IN_PROGRESS, start_ip_addresses_by_host: blue_ip_map))
          provider.prepare_status(role::SOURCE, source_status(phase: phase::POST, start_ip_addresses_by_host: blue_ip_map))
          expect(current_marker.active?).to be(true)

          allow_any_instance_of(bg::SwitchoverTimer).to receive(:expired?).and_return(true)
          provider.prepare_status(role::SOURCE, source_status(phase: phase::POST, start_ip_addresses_by_host: blue_ip_map))

          expect(current_marker.active?).to be(true)
        end
      end

      context 'when bg_drop_blue_connections is disabled' do
        let(:props) { Concurrent::Map.new.tap { |p| p[:bg_drop_blue_connections] = false } }

        it 'never creates a marker' do
          provider.prepare_status(role::SOURCE, source_status(phase: phase::IN_PROGRESS, start_ip_addresses_by_host: blue_ip_map))
          provider.prepare_status(role::SOURCE, source_status(phase: phase::POST, start_ip_addresses_by_host: blue_ip_map))
          expect(markers).to be_empty
        end
      end
    end
  end
end
