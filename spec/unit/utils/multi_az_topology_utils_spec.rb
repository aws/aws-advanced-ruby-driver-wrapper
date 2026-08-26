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
require 'aws_ruby_driver_wrapper/utils/multi_az_topology_utils'
require 'aws_ruby_driver_wrapper/host/host_info'
require 'aws_ruby_driver_wrapper/host/host_role'

RSpec.describe AwsRubyDriverWrapper::Utils::MultiAzTopologyUtils do
  include ResultSetHelper

  let(:dialect) { instance_double('Dialect') }
  let(:conn) { double('connection') }
  let(:subject) { described_class.new(dialect: dialect) }

  let(:initial_host_info) do
    AwsRubyDriverWrapper::Host::HostInfo.new(
      host: 'my-cluster.cluster-xyz.us-east-1.rds.amazonaws.com',
      port: 5432
    )
  end

  let(:instance_template) do
    AwsRubyDriverWrapper::Host::HostInfo.new(
      host: '?.xyz.us-east-1.rds.amazonaws.com',
      port: 5432
    )
  end

  describe '#writer_instance?' do
    before do
      allow(dialect).to receive(:writer_id_query).and_return('SELECT writer_id()')
    end

    context 'when connected to a writer' do
      it 'returns true when writer_id_query returns nil' do
        allow(dialect).to receive(:execute).with(conn, 'SELECT writer_id()').and_return(nil)
        expect(subject.writer_instance?(conn)).to be true
      end

      it 'returns true when writer_id_query returns empty results' do
        allow(dialect).to receive(:execute).with(conn, 'SELECT writer_id()').and_return([])
        expect(subject.writer_instance?(conn)).to be true
      end
    end

    context 'when connected to a reader' do
      it 'returns false when writer_id_query returns a row' do
        allow(dialect).to receive(:execute).with(conn, 'SELECT writer_id()').and_return(
          [{ 'writer_id' => 'writer-instance-id' }]
        )
        expect(subject.writer_instance?(conn)).to be false
      end
    end
  end

  describe '#query_topology' do
    let(:topology_query) { 'SELECT endpoint FROM ...' }
    let(:writer_id_query) { 'SELECT writer_id()' }

    before do
      allow(dialect).to receive(:topology_query).and_return(topology_query)
      allow(dialect).to receive(:writer_id_query).and_return(writer_id_query)
    end

    context 'when connected to a reader and topology returns valid results' do
      it 'returns hosts with the correct writer identified' do
        # writer_id_query returns the writer ID when connected to a reader
        allow(dialect).to receive(:execute).with(conn, writer_id_query).and_return(
          [{ 'writer_id' => '123456789' }]
        )
        allow(dialect).to receive(:writer_id_column_name).and_return('writer_id')

        results = make_result_set(
          %w[endpoint],
          [
            { 'instance_id' => '123456789', 'endpoint' => 'writer-instance.xyz.us-east-1.rds.amazonaws.com' },
            { 'instance_id' => '987654321', 'endpoint' => 'reader-instance.xyz.us-east-1.rds.amazonaws.com' }
          ]
        )
        allow(dialect).to receive(:execute).with(conn, topology_query).and_return(results)

        hosts = subject.query_topology(conn, initial_host_info, instance_template)

        expect(hosts).not_to be_nil
        expect(hosts.size).to eq(2)

        writer = hosts.find { |h| h.role == AwsRubyDriverWrapper::Host::HostRole::WRITER }
        reader = hosts.find { |h| h.role == AwsRubyDriverWrapper::Host::HostRole::READER }

        expect(writer).not_to be_nil
        expect(writer.id).to eq('123456789')
        expect(reader).not_to be_nil
        expect(reader.id).to eq('987654321')
      end
    end

    context 'when connected to a writer' do
      it 'uses instance_id to determine the writer' do
        # When connected to writer, writer_id_query returns empty
        allow(dialect).to receive(:execute).with(conn, writer_id_query).and_return([])
        allow(dialect).to receive(:instance_identity).with(conn).and_return(%w[123456789 current-writer])

        results = make_result_set(
          %w[endpoint],
          [
            { 'instance_id' => '123456789', 'endpoint' => 'current-writer.xyz.us-east-1.rds.amazonaws.com' },
            { 'instance_id' => '987654321', 'endpoint' => 'reader-1.xyz.us-east-1.rds.amazonaws.com' }
          ]
        )
        allow(dialect).to receive(:execute).with(conn, topology_query).and_return(results)

        hosts = subject.query_topology(conn, initial_host_info, instance_template)

        expect(hosts).not_to be_nil
        writer = hosts.find { |h| h.role == AwsRubyDriverWrapper::Host::HostRole::WRITER }
        expect(writer).not_to be_nil
        expect(writer.id).to eq('123456789')
      end
    end

    context 'when the query returns zero columns' do
      it 'returns nil' do
        results = make_result_set([], [])
        allow(dialect).to receive(:execute).with(conn, topology_query).and_return(results)

        expect(subject.query_topology(conn, initial_host_info, instance_template)).to be_nil
      end
    end

    context 'when there are no writers' do
      it 'returns nil' do
        allow(dialect).to receive(:execute).with(conn, writer_id_query).and_return([])
        allow(dialect).to receive(:instance_identity).with(conn).and_return('unknown-id', 'unknown-host')

        results = make_result_set(
          %w[endpoint],
          [
            { 'endpoint' => 'reader-1.xyz.us-east-1.rds.amazonaws.com' },
            { 'endpoint' => 'reader-2.xyz.us-east-1.rds.amazonaws.com' }
          ]
        )
        allow(dialect).to receive(:execute).with(conn, topology_query).and_return(results)

        expect(subject.query_topology(conn, initial_host_info, instance_template)).to be_nil
      end
    end

    context 'when the writer_id_query raises an error' do
      it 'returns nil when no writer can be identified' do
        allow(dialect).to receive(:execute).with(conn, writer_id_query).and_raise(StandardError, 'connection lost')

        results = make_result_set(
          %w[endpoint],
          [
            { 'instance_id' => '123456789', 'endpoint' => 'instance-1.xyz.us-east-1.rds.amazonaws.com' }
          ]
        )
        allow(dialect).to receive(:execute).with(conn, topology_query).and_return(results)

        # writer_id will be nil, so no host matches as writer => verify_writer returns nil
        expect(subject.query_topology(conn, initial_host_info, instance_template)).to be_nil
      end
    end

    context 'when endpoint is used to extract instance ID' do
      it 'extracts the instance ID from the endpoint (text before first dot)' do
        allow(dialect).to receive(:execute).with(conn, writer_id_query).and_return(
          [{ 'writer_id' => '123456789' }]
        )
        allow(dialect).to receive(:writer_id_column_name).and_return('writer_id')

        results = make_result_set(
          %w[id endpoint],
          [
            { 'instance_id' => '123456789', 'endpoint' => 'my-writer.some.long.hostname.com' }
          ]
        )
        allow(dialect).to receive(:execute).with(conn, topology_query).and_return(results)

        hosts = subject.query_topology(conn, initial_host_info, instance_template)

        expect(hosts).not_to be_nil
        expect(hosts.first.id).to eq('123456789')
      end
    end
  end
end
