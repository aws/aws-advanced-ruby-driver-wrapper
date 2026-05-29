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
require 'aws_ruby_database_driver_wrapper/utils/aurora_topology_utils'
require 'aws_ruby_database_driver_wrapper/host/host_info'
require 'aws_ruby_database_driver_wrapper/host/host_role'

RSpec.describe AwsRubyDatabaseDriverWrapper::Utils::AuroraTopologyUtils do
  include ResultSetHelper

  let(:dialect) { instance_double('Dialect') }
  let(:conn) { double('connection') }
  let(:subject) { described_class.new(dialect: dialect) }

  let(:initial_host_info) do
    AwsRubyDatabaseDriverWrapper::Host::HostInfo.new(
      host: 'my-cluster.cluster-xyz.us-east-1.rds.amazonaws.com',
      port: 5432
    )
  end

  let(:instance_template) do
    AwsRubyDatabaseDriverWrapper::Host::HostInfo.new(
      host: '?.xyz.us-east-1.rds.amazonaws.com',
      port: 5432
    )
  end

  describe '#writer_instance?' do
    context 'when connected to a writer' do
      it 'returns true when writer_id_query returns a non-empty value' do
        allow(dialect).to receive(:writer_id_query).and_return('SELECT writer_id()')
        allow(dialect).to receive(:execute).with(conn, 'SELECT writer_id()').and_return(
          [{ 'server_id' => 'writer-instance' }]
        )

        expect(subject.writer_instance?(conn)).to be true
      end
    end

    context 'when connected to a reader' do
      it 'returns false when writer_id_query returns nil results' do
        allow(dialect).to receive(:writer_id_query).and_return('SELECT writer_id()')
        allow(dialect).to receive(:execute).with(conn, 'SELECT writer_id()').and_return(nil)

        expect(subject.writer_instance?(conn)).to be false
      end

      it 'returns false when writer_id_query returns empty results' do
        allow(dialect).to receive(:writer_id_query).and_return('SELECT writer_id()')
        allow(dialect).to receive(:execute).with(conn, 'SELECT writer_id()').and_return([])

        expect(subject.writer_instance?(conn)).to be false
      end

      it 'returns false when the first row has a nil value' do
        allow(dialect).to receive(:writer_id_query).and_return('SELECT writer_id()')
        allow(dialect).to receive(:execute).with(conn, 'SELECT writer_id()').and_return(
          [{ 'server_id' => nil }]
        )

        expect(subject.writer_instance?(conn)).to be false
      end

      it 'returns false when the first row has an empty string value' do
        allow(dialect).to receive(:writer_id_query).and_return('SELECT writer_id()')
        allow(dialect).to receive(:execute).with(conn, 'SELECT writer_id()').and_return(
          [{ 'server_id' => '' }]
        )

        expect(subject.writer_instance?(conn)).to be false
      end
    end
  end

  describe '#query_topology' do
    let(:topology_query) { 'SELECT ...' }
    let(:now) { Time.now }

    before do
      allow(dialect).to receive(:topology_query).and_return(topology_query)
    end

    context 'when the query returns valid results' do
      it 'returns a list of hosts with one writer and one reader' do
        results = make_result_set(
          %w[instance_id is_writer cpu_utilization instance_lag last_update_time],
          [
            { 'instance_id' => 'writer-instance', 'is_writer' => true, 'cpu_utilization' => 25.0,
              'instance_lag' => 0.0, 'last_update_time' => now },
            { 'instance_id' => 'reader-instance', 'is_writer' => false, 'cpu_utilization' => 10.0,
              'instance_lag' => 1.0, 'last_update_time' => now }
          ]
        )
        allow(dialect).to receive(:execute).with(conn, topology_query).and_return(results)

        hosts = subject.query_topology(conn, initial_host_info, instance_template)

        expect(hosts).not_to be_nil
        expect(hosts.size).to eq(2)

        writer = hosts.find { |h| h.role == AwsRubyDatabaseDriverWrapper::Host::HostRole::WRITER }
        reader = hosts.find { |h| h.role == AwsRubyDatabaseDriverWrapper::Host::HostRole::READER }

        expect(writer).not_to be_nil
        expect(writer.id).to eq('writer-instance')
        expect(reader).not_to be_nil
        expect(reader.id).to eq('reader-instance')
      end

      it 'calculates weight from instance_lag and cpu_utilization' do
        results = make_result_set(
          %w[instance_id is_writer cpu_utilization instance_lag last_update_time],
          [
            { 'instance_id' => 'instance-1', 'is_writer' => true, 'cpu_utilization' => 30.0,
              'instance_lag' => 2.0, 'last_update_time' => now }
          ]
        )
        allow(dialect).to receive(:execute).with(conn, topology_query).and_return(results)

        hosts = subject.query_topology(conn, initial_host_info, instance_template)

        expect(hosts).not_to be_nil
        # weight = (instance_lag.round * 100) + cpu_utilization.round = (2 * 100) + 30 = 230
        expect(hosts.first.weight).to eq(230)
      end

      it 'deduplicates hosts keeping the most recent record' do
        older_time = Time.now - 60
        newer_time = Time.now

        results = make_result_set(
          %w[instance_id is_writer cpu_utilization instance_lag last_update_time],
          [
            { 'instance_id' => 'instance-1', 'is_writer' => true, 'cpu_utilization' => 50.0,
              'instance_lag' => 0.0, 'last_update_time' => older_time },
            { 'instance_id' => 'instance-1', 'is_writer' => true, 'cpu_utilization' => 10.0,
              'instance_lag' => 0.0, 'last_update_time' => newer_time }
          ]
        )
        allow(dialect).to receive(:execute).with(conn, topology_query).and_return(results)

        hosts = subject.query_topology(conn, initial_host_info, instance_template)

        expect(hosts).not_to be_nil
        expect(hosts.size).to eq(1)
        # Should keep the newer record with cpu_utilization 10
        expect(hosts.first.weight).to eq(10)
      end
    end

    context 'when the query returns zero columns' do
      it 'returns nil' do
        results = make_result_set([], [])
        allow(dialect).to receive(:execute).with(conn, topology_query).and_return(results)

        expect(subject.query_topology(conn, initial_host_info, instance_template)).to be_nil
      end
    end

    context 'when there are multiple writers' do
      it 'selects the writer with the most recent last_update_time' do
        older_time = Time.now - 120
        newer_time = Time.now

        results = make_result_set(
          %w[instance_id is_writer cpu_utilization instance_lag last_update_time],
          [
            { 'instance_id' => 'old-writer', 'is_writer' => true, 'cpu_utilization' => 10.0,
              'instance_lag' => 0.0, 'last_update_time' => older_time },
            { 'instance_id' => 'new-writer', 'is_writer' => true, 'cpu_utilization' => 20.0,
              'instance_lag' => 0.0, 'last_update_time' => newer_time },
            { 'instance_id' => 'reader-1', 'is_writer' => false, 'cpu_utilization' => 5.0,
              'instance_lag' => 1.0, 'last_update_time' => newer_time }
          ]
        )
        allow(dialect).to receive(:execute).with(conn, topology_query).and_return(results)

        hosts = subject.query_topology(conn, initial_host_info, instance_template)

        expect(hosts).not_to be_nil
        writer = hosts.find { |h| h.role == AwsRubyDatabaseDriverWrapper::Host::HostRole::WRITER }
        expect(writer.id).to eq('new-writer')
      end
    end

    context 'when there are no writers' do
      it 'returns nil' do
        results = make_result_set(
          %w[instance_id is_writer cpu_utilization instance_lag last_update_time],
          [
            { 'instance_id' => 'reader-1', 'is_writer' => false, 'cpu_utilization' => 5.0,
              'instance_lag' => 1.0, 'last_update_time' => now }
          ]
        )
        allow(dialect).to receive(:execute).with(conn, topology_query).and_return(results)

        expect(subject.query_topology(conn, initial_host_info, instance_template)).to be_nil
      end
    end

    context 'when instance_id is nil' do
      it 'uses ? as a placeholder in the URL' do
        results = make_result_set(
          %w[instance_id is_writer cpu_utilization instance_lag last_update_time],
          [
            { 'instance_id' => nil, 'is_writer' => true, 'cpu_utilization' => 10.0,
              'instance_lag' => 0.0, 'last_update_time' => now }
          ]
        )
        allow(dialect).to receive(:execute).with(conn, topology_query).and_return(results)

        hosts = subject.query_topology(conn, initial_host_info, instance_template)

        expect(hosts).not_to be_nil
        expect(hosts.first.host).to eq('?.xyz.us-east-1.rds.amazonaws.com')
      end
    end

    context 'when row values use symbol keys' do
      it 'handles symbol keys correctly' do
        results = make_result_set(
          %w[instance_id is_writer cpu_utilization instance_lag last_update_time],
          [
            { instance_id: 'instance-1', is_writer: true, cpu_utilization: 15.0,
              instance_lag: 0.0, last_update_time: now }
          ]
        )
        allow(dialect).to receive(:execute).with(conn, topology_query).and_return(results)

        hosts = subject.query_topology(conn, initial_host_info, instance_template)

        expect(hosts).not_to be_nil
        expect(hosts.first.id).to eq('instance-1')
      end
    end
  end
end
