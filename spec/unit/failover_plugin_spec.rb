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

require_relative '../spec_helper'
require 'aws_ruby_driver_wrapper/plugins/failover_plugin'
require 'aws_ruby_driver_wrapper/plugins/failover_mode'
require 'aws_ruby_driver_wrapper/property_definition'
require 'aws_ruby_driver_wrapper/services/service_container'
require 'aws_ruby_driver_wrapper/host/host_info'
require 'aws_ruby_driver_wrapper/host/host_role'
require 'aws_ruby_driver_wrapper/host/host_availability'
require 'aws_ruby_driver_wrapper/ruby_method'

RSpec.describe AwsRubyDriverWrapper::Plugins::FailoverPlugin do
  let(:host_role) { AwsRubyDriverWrapper::Host::HostRole }
  let(:host_availability) { AwsRubyDriverWrapper::Host::HostAvailability }
  let(:failover_mode) { AwsRubyDriverWrapper::Plugins::FailoverMode }

  let(:writer_host) do
    AwsRubyDriverWrapper::Host::HostInfo.new(
      host: 'writer-instance.xyz.us-east-1.rds.amazonaws.com',
      port: '5432',
      role: host_role::WRITER
    )
  end

  let(:reader_host) do
    AwsRubyDriverWrapper::Host::HostInfo.new(
      host: 'reader-instance.xyz.us-east-1.rds.amazonaws.com',
      port: '5432',
      role: host_role::READER
    )
  end

  let(:connection) { double('connection') }
  let(:new_connection) { double('new_connection') }

  let(:driver_dialect) do
    double('driver_dialect',
           network_bound_methods: Set['connection.exec', 'connection.query'],
           closed?: false,
           close_connection: nil,
           execute: nil)
  end

  let(:db_dialect) do
    double('db_dialect', host_role: host_role::WRITER)
  end

  let(:dialect_service) do
    double('dialect_service',
           driver_dialect: driver_dialect,
           db_dialect: db_dialect,
           network_error?: false,
           read_only_error?: false)
  end

  let(:session_state_service) do
    double('session_state_service', in_transaction?: false, 'in_transaction=': nil)
  end

  let(:host_service) do
    double('host_service',
           all_hosts: [writer_host, reader_host],
           hosts: [writer_host, reader_host],
           refresh_host_list: nil,
           force_refresh_host_list?: true,
           set_availability: nil,
           select_host: reader_host)
  end

  let(:connection_service) do
    double('connection_service',
           current_connection: connection,
           current_host_info: writer_host,
           initial_host_info: writer_host,
           'initial_host_info=': nil,
           update_current_connection: nil,
           driver_props: props)
  end

  let(:plugin_manager) do
    double('plugin_manager', connect: new_connection)
  end

  let(:retry_util) do
    double('retry_util')
  end

  let(:service_container) do
    AwsRubyDriverWrapper::Services::ServiceContainer.new(
      connection_service,
      dialect_service,
      nil,
      host_service,
      plugin_manager,
      session_state_service,
      nil,
      nil
    )
  end

  let(:props) { Concurrent::Map.new }
  let(:plugin) { described_class.new(service_container, props) }

  before do
    allow(AwsRubyDriverWrapper::Utils::RetryUtil).to receive(:new).and_return(retry_util)
  end

  describe '#subscribed_methods' do
    it 'includes connect' do
      expect(plugin.subscribed_methods).to include('connect')
    end

    it 'includes network-bound methods from the driver dialect' do
      expect(plugin.subscribed_methods).to include('connection.exec')
      expect(plugin.subscribed_methods).to include('connection.query')
    end
  end

  describe '#execute' do
    let(:pipeline_callable) { -> { :result } }

    context 'when method can be directly executed' do
      it 'passes through connection.close without failover logic' do
        result = plugin.execute(
          AwsRubyDriverWrapper::RubyMethod::CONNECTION_CLOSE.name,
          pipeline_callable
        )
        expect(result).to eq(:result)
      end

      it 'sets closed_explicitly on connection.close' do
        plugin.execute(
          AwsRubyDriverWrapper::RubyMethod::CONNECTION_CLOSE.name,
          pipeline_callable
        )

        # Subsequent failover should be skipped since connection was explicitly closed
        plugin.send(:failover)
      end

      it 'passes through connection.close without failover logic' do
        result = plugin.execute(
          AwsRubyDriverWrapper::RubyMethod::CONNECTION_CLOSE.name,
          pipeline_callable
        )
        expect(result).to eq(:result)
      end
    end

    context 'when the current connection is closed unexpectedly' do
      before do
        allow(db_dialect).to receive(:host_role).and_return(host_role::READER)
        props[:failover_mode] = 'reader_or_writer'
        plugin.connect(reader_host, props, true, -> { connection })

        allow(driver_dialect).to receive(:closed?).and_return(true)
        allow(host_service).to receive(:all_hosts).and_return([writer_host, reader_host])
        allow(host_service).to receive(:force_refresh_host_list?).and_return(true)
        allow(db_dialect).to receive(:host_role).and_return(host_role::READER)
        allow(plugin_manager).to receive(:connect).and_return(new_connection)
        allow(connection_service).to receive(:update_current_connection)
        allow(connection_service).to receive(:current_connection).and_return(new_connection)
      end

      it 'triggers failover' do
        expect(host_service).to receive(:force_refresh_host_list?)
        expect do
          plugin.execute('connection.exec', pipeline_callable)
        end.to raise_error(AwsRubyDriverWrapper::Errors::FailoverSuccessError)
      end
    end

    context 'when a network error occurs during execution' do
      let(:network_error) { StandardError.new('connection lost') }
      let(:pipeline_callable) { -> { raise network_error } }

      before do
        # init_failover_mode must have run (normally happens during connect)
        allow(db_dialect).to receive(:host_role).and_return(host_role::WRITER)
        plugin.connect(writer_host, props, true, -> { connection })

        allow(dialect_service).to receive(:network_error?).with(network_error).and_return(true)
        allow(host_service).to receive(:force_refresh_host_list?).and_return(true)
        allow(connection_service).to receive(:update_current_connection)
        writer_result = AwsRubyDriverWrapper::Utils::RetryUtil::Result.new(new_connection, writer_host)
        allow(retry_util).to receive(:connect_to_writer).and_return(writer_result)
      end

      it 'invalidates current connection and triggers failover' do
        allow(driver_dialect).to receive(:close_connection)
        expect(host_service).to receive(:set_availability).with(writer_host, host_availability::UNAVAILABLE)
        expect do
          plugin.execute('connection.exec', pipeline_callable)
        end.to raise_error(AwsRubyDriverWrapper::Errors::FailoverSuccessError)
      end
    end

    context 'when a non-network error occurs' do
      let(:app_error) { StandardError.new('syntax error') }
      let(:pipeline_callable) { -> { raise app_error } }

      before do
        allow(dialect_service).to receive(:network_error?).with(app_error).and_return(false)
      end

      it 'raises the error without triggering failover' do
        expect(driver_dialect).not_to receive(:close_connection)
        expect { plugin.execute('connection.exec', pipeline_callable) }.to raise_error(StandardError, 'syntax error')
      end
    end

    context 'when a read-only error occurs in STRICT_WRITER mode' do
      let(:read_only_error) { StandardError.new('read only') }
      let(:pipeline_callable) { -> { raise read_only_error } }

      before do
        props[:failover_mode] = 'strict_writer'
        # init_failover_mode must have run
        allow(db_dialect).to receive(:host_role).and_return(host_role::WRITER)
        plugin.connect(writer_host, props, true, -> { connection })

        allow(dialect_service).to receive(:network_error?).and_return(false)
        allow(dialect_service).to receive(:read_only_error?).with(read_only_error).and_return(true)
        allow(host_service).to receive(:force_refresh_host_list?).and_return(true)
        allow(connection_service).to receive(:update_current_connection)
        writer_result = AwsRubyDriverWrapper::Utils::RetryUtil::Result.new(new_connection, writer_host)
        allow(retry_util).to receive(:connect_to_writer).and_return(writer_result)
      end

      it 'triggers failover' do
        allow(driver_dialect).to receive(:close_connection)
        expect(host_service).to receive(:set_availability).with(writer_host, host_availability::UNAVAILABLE)
        expect do
          plugin.execute('connection.exec', pipeline_callable)
        end.to raise_error(AwsRubyDriverWrapper::Errors::FailoverSuccessError)
      end
    end
  end

  describe '#connect' do
    let(:pipeline_callable) { -> { connection } }

    context 'when connect failover is disabled' do
      it 'returns the connection from the pipeline' do
        allow(db_dialect).to receive(:host_role).with(connection).and_return(host_role::WRITER)
        result = plugin.connect(writer_host, props, true, pipeline_callable)
        expect(result).to eq(connection)
      end
    end

    context 'when connect failover is enabled and host is unavailable' do
      before do
        props[:enable_connect_failover] = true
        allow(reader_host).to receive(:availability).and_return(host_availability::UNAVAILABLE)
        allow(host_service).to receive(:hosts).and_return([reader_host])
        allow(host_service).to receive(:force_refresh_host_list?).and_return(true)
        allow(connection_service).to receive(:current_connection).and_return(new_connection)
        allow(connection_service).to receive(:update_current_connection)
        writer_result = AwsRubyDriverWrapper::Utils::RetryUtil::Result.new(new_connection, writer_host)
        allow(retry_util).to receive(:connect_to_writer).and_return(writer_result)
      end

      it 'refreshes host list, performs failover, and returns the new connection' do
        expect(host_service).to receive(:refresh_host_list).at_least(:once)
        result = plugin.connect(reader_host, props, true, pipeline_callable)
        expect(result).to eq(new_connection)
      end
    end

    context 'when connect failover is enabled and connection raises a network error' do
      let(:network_error) { StandardError.new('connection refused') }
      let(:failing_callable) { -> { raise network_error } }

      let(:non_cluster_host) do
        AwsRubyDriverWrapper::Host::HostInfo.new(
          host: 'my-instance.xyz.us-east-1.rds.amazonaws.com',
          port: '5432',
          role: host_role::WRITER
        )
      end

      before do
        props[:enable_connect_failover] = true
        allow(connection_service).to receive(:initial_host_info).and_return(non_cluster_host)
        allow(dialect_service).to receive(:network_error?).with(network_error).and_return(true)
        allow(host_service).to receive(:force_refresh_host_list?).and_return(true)
        allow(connection_service).to receive(:current_connection).and_return(new_connection)
        allow(connection_service).to receive(:update_current_connection)
        writer_result = AwsRubyDriverWrapper::Utils::RetryUtil::Result.new(new_connection, writer_host)
        allow(retry_util).to receive(:connect_to_writer).and_return(writer_result)
      end

      it 'marks host unavailable, performs failover, and returns the new connection' do
        expect(host_service).to receive(:set_availability).with(non_cluster_host, host_availability::UNAVAILABLE)
        result = plugin.connect(non_cluster_host, props, false, failing_callable)
        expect(result).to eq(new_connection)
      end
    end
  end

  describe 'verified_connection (stale DNS)' do
    let(:pipeline_callable) { -> { connection } }

    context 'when host is not a writer cluster endpoint' do
      it 'returns the connection without verification' do
        result = plugin.connect(writer_host, props, true, pipeline_callable)
        expect(result).to eq(connection)
      end
    end

    context 'when writer cluster resolves to the writer' do
      let(:writer_cluster_host) do
        AwsRubyDriverWrapper::Host::HostInfo.new(
          host: 'my-cluster.cluster-xyz.us-east-1.rds.amazonaws.com',
          port: '5432',
          role: host_role::WRITER
        )
      end

      before do
        allow(connection_service).to receive(:initial_host_info).and_return(writer_cluster_host)
        allow(db_dialect).to receive(:host_role).with(connection).and_return(host_role::WRITER)
      end

      it 'returns the connection and refreshes host list' do
        expect(host_service).to receive(:refresh_host_list)
        result = plugin.connect(writer_cluster_host, props, true, pipeline_callable)
        expect(result).to eq(connection)
      end
    end

    context 'when writer cluster resolves to a reader (stale DNS)' do
      let(:writer_cluster_host) do
        AwsRubyDriverWrapper::Host::HostInfo.new(
          host: 'my-cluster.cluster-xyz.us-east-1.rds.amazonaws.com',
          port: '5432',
          role: host_role::WRITER
        )
      end

      before do
        allow(connection_service).to receive(:initial_host_info).and_return(writer_cluster_host)
        allow(db_dialect).to receive(:host_role).with(connection).and_return(host_role::READER)
        allow(host_service).to receive(:force_refresh_host_list?).and_return(true)
        allow(host_service).to receive(:all_hosts).and_return([writer_host, reader_host])
        allow(plugin_manager).to receive(:connect).and_return(new_connection)
      end

      it 'redirects to the writer instance' do
        expect(plugin_manager).to receive(:connect).with(writer_host, props, false, plugin_to_skip: plugin)
        expect(driver_dialect).to receive(:close_connection).with(connection)
        result = plugin.connect(writer_cluster_host, props, true, pipeline_callable)
        expect(result).to eq(new_connection)
      end
    end
  end

  describe 'failover_reader' do
    before do
      props[:failover_timeout_sec] = 5
      props[:failover_mode] = 'reader_or_writer'
      allow(db_dialect).to receive(:host_role).and_return(host_role::READER)
      plugin.connect(writer_host, props, true, -> { connection })

      allow(host_service).to receive(:force_refresh_host_list?).and_return(true)
      allow(plugin_manager).to receive(:connect).and_return(new_connection)
      allow(db_dialect).to receive(:host_role).and_return(host_role::READER)
      allow(connection_service).to receive(:update_current_connection)
      allow(connection_service).to receive(:current_connection).and_return(new_connection)
    end

    it 'connects to a reader and raises FailoverSuccessError' do
      expect(connection_service).to receive(:update_current_connection).with(new_connection, anything)
      expect do
        plugin.send(:failover)
      end.to raise_error(AwsRubyDriverWrapper::Errors::FailoverSuccessError)
    end
  end

  describe 'failover_writer' do
    before do
      props[:failover_timeout_sec] = 5
      props[:failover_mode] = 'strict_writer'
      allow(db_dialect).to receive(:host_role).and_return(host_role::WRITER)
      plugin.connect(writer_host, props, true, -> { connection })

      allow(host_service).to receive(:force_refresh_host_list?).and_return(true)
      writer_result = AwsRubyDriverWrapper::Utils::RetryUtil::Result.new(new_connection, writer_host)
      allow(retry_util).to receive(:connect_to_writer).and_return(writer_result)
      allow(connection_service).to receive(:update_current_connection)
      allow(connection_service).to receive(:current_connection).and_return(new_connection)
    end

    it 'connects to a writer and raises FailoverSuccessError' do
      expect(connection_service).to receive(:update_current_connection).with(new_connection, anything)
      expect do
        plugin.send(:failover)
      end.to raise_error(AwsRubyDriverWrapper::Errors::FailoverSuccessError)
    end

    context 'when in a transaction' do
      before do
        allow(session_state_service).to receive(:in_transaction?).and_return(true)
        allow(session_state_service).to receive(:in_transaction=)
      end

      it 'raises TransactionStateUnknownError' do
        expect do
          plugin.send(:failover)
        end.to raise_error(AwsRubyDriverWrapper::Errors::TransactionStateUnknownError)
      end

      it 'resets the transaction state' do
        expect(session_state_service).to receive(:in_transaction=).with(false)
        begin
          plugin.send(:failover)
        rescue AwsRubyDriverWrapper::Errors::TransactionStateUnknownError
          nil
        end
      end
    end
  end

  describe 'failover mode initialization' do
    context 'when failover_mode is set explicitly' do
      before { props[:failover_mode] = 'strict_reader' }

      it 'uses the explicit mode' do
        allow(db_dialect).to receive(:host_role).and_return(host_role::WRITER)
        plugin.connect(writer_host, props, true, -> { connection })
        expect(plugin.send(:instance_variable_get, :@failover_mode)).to eq(failover_mode::STRICT_READER)
      end
    end

    context 'when failover_mode is not set and connecting to a reader cluster' do
      let(:reader_cluster_host) do
        AwsRubyDriverWrapper::Host::HostInfo.new(
          host: 'my-cluster.cluster-ro-xyz.us-east-1.rds.amazonaws.com',
          port: '5432',
          role: host_role::READER
        )
      end

      before do
        allow(connection_service).to receive(:initial_host_info).and_return(reader_cluster_host)
        allow(db_dialect).to receive(:host_role).and_return(host_role::READER)
      end

      it 'defaults to READER_OR_WRITER' do
        plugin.connect(reader_cluster_host, props, true, -> { connection })
        expect(plugin.send(:instance_variable_get, :@failover_mode)).to eq(failover_mode::READER_OR_WRITER)
      end
    end

    context 'when failover_mode is not set and connecting to a writer cluster' do
      before do
        allow(db_dialect).to receive(:host_role).and_return(host_role::WRITER)
      end

      it 'defaults to STRICT_WRITER' do
        plugin.connect(writer_host, props, true, -> { connection })
        expect(plugin.send(:instance_variable_get, :@failover_mode)).to eq(failover_mode::STRICT_WRITER)
      end
    end
  end
end
