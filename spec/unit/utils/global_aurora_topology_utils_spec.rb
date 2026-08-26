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
require 'aws_ruby_driver_wrapper/utils/global_aurora_topology_utils'
require 'aws_ruby_driver_wrapper/host/host_info'
require 'aws_ruby_driver_wrapper/host/host_role'

RSpec.describe AwsRubyDriverWrapper::Utils::GlobalAuroraTopologyUtils do
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

  let(:us_east_template) do
    AwsRubyDriverWrapper::Host::HostInfo.new(
      host: '?.xyz.us-east-1.rds.amazonaws.com',
      port: 5432
    )
  end

  let(:eu_west_template) do
    AwsRubyDriverWrapper::Host::HostInfo.new(
      host: '?.xyz.eu-west-1.rds.amazonaws.com',
      port: 5432
    )
  end

  let(:instance_templates_by_region) do
    {
      'us-east-1' => us_east_template,
      'eu-west-1' => eu_west_template
    }
  end

  describe '#query_topology' do
    let(:topology_query) { 'SELECT ...' }

    before do
      allow(dialect).to receive(:topology_query).and_return(topology_query)
    end

    context 'when the query returns valid multi-region results' do
      it 'returns hosts from multiple regions with correct templates applied' do
        results = make_result_set(
          %w[instance_id is_writer instance_lag aws_region],
          [
            { 'instance_id' => 'writer-instance', 'is_writer' => true, 'instance_lag' => 0.0, 'aws_region' => 'us-east-1' },
            { 'instance_id' => 'reader-instance', 'is_writer' => false, 'instance_lag' => 1.5, 'aws_region' => 'eu-west-1' }
          ]
        )
        allow(dialect).to receive(:execute).with(conn, topology_query).and_return(results)

        hosts = subject.query_global_topology(conn, initial_host_info, instance_templates_by_region)

        expect(hosts).not_to be_nil
        expect(hosts.size).to eq(2)

        writer = hosts.find { |h| h.role == AwsRubyDriverWrapper::Host::HostRole::WRITER }
        reader = hosts.find { |h| h.role == AwsRubyDriverWrapper::Host::HostRole::READER }

        expect(writer).not_to be_nil
        expect(writer.id).to eq('writer-instance')
        expect(writer.host).to eq('writer-instance.xyz.us-east-1.rds.amazonaws.com')

        expect(reader).not_to be_nil
        expect(reader.id).to eq('reader-instance')
        expect(reader.host).to eq('reader-instance.xyz.eu-west-1.rds.amazonaws.com')
      end

      it 'calculates weight from instance_lag' do
        results = make_result_set(
          %w[instance_id is_writer instance_lag aws_region],
          [
            { 'instance_id' => 'instance-1', 'is_writer' => true, 'instance_lag' => 3.0, 'aws_region' => 'us-east-1' }
          ]
        )
        allow(dialect).to receive(:execute).with(conn, topology_query).and_return(results)

        hosts = subject.query_global_topology(conn, initial_host_info, instance_templates_by_region)

        expect(hosts).not_to be_nil
        # weight = instance_lag.round * 100 = 3 * 100 = 300
        expect(hosts.first.weight).to eq(300)
      end
    end

    context 'when the query returns zero columns' do
      it 'returns nil' do
        results = make_result_set([], [])
        allow(dialect).to receive(:execute).with(conn, topology_query).and_return(results)

        expect(subject.query_global_topology(conn, initial_host_info, instance_templates_by_region)).to be_nil
      end
    end

    context 'when there are no writers' do
      it 'returns nil' do
        results = make_result_set(
          %w[instance_id is_writer instance_lag aws_region],
          [
            { 'instance_id' => 'reader-1', 'is_writer' => false, 'instance_lag' => 1.0, 'aws_region' => 'us-east-1' }
          ]
        )
        allow(dialect).to receive(:execute).with(conn, topology_query).and_return(results)

        expect(subject.query_global_topology(conn, initial_host_info, instance_templates_by_region)).to be_nil
      end
    end

    context 'when a row has an unknown region' do
      it 'returns nil' do
        results = make_result_set(
          %w[instance_id is_writer instance_lag aws_region],
          [
            { 'instance_id' => 'instance-1', 'is_writer' => true, 'instance_lag' => 0.0, 'aws_region' => 'ap-southeast-1' }
          ]
        )
        allow(dialect).to receive(:execute).with(conn, topology_query).and_return(results)

        expect(subject.query_global_topology(conn, initial_host_info, instance_templates_by_region)).to be_nil
      end
    end

    context 'when multiple writers exist' do
      it 'selects only one writer' do
        results = make_result_set(
          %w[instance_id is_writer instance_lag aws_region],
          [
            { 'instance_id' => 'writer-1', 'is_writer' => true, 'instance_lag' => 0.0, 'aws_region' => 'us-east-1' },
            { 'instance_id' => 'writer-2', 'is_writer' => true, 'instance_lag' => 0.0, 'aws_region' => 'eu-west-1' },
            { 'instance_id' => 'reader-1', 'is_writer' => false, 'instance_lag' => 2.0, 'aws_region' => 'us-east-1' }
          ]
        )
        allow(dialect).to receive(:execute).with(conn, topology_query).and_return(results)

        hosts = subject.query_global_topology(conn, initial_host_info, instance_templates_by_region)

        expect(hosts).not_to be_nil
        writers = hosts.select { |h| h.role == AwsRubyDriverWrapper::Host::HostRole::WRITER }
        # verify_writer keeps only one writer (the most recent)
        expect(writers.size).to eq(1)
      end
    end
  end

  describe '#query_region' do
    it 'returns the region for a given instance ID' do
      allow(dialect).to receive(:region_by_instance_id_query).and_return('SELECT region ...')
      allow(dialect).to receive(:execute_with_params).with(conn, 'SELECT region ...', ['my-instance']).and_return(
        [{ 'aws_region' => 'us-east-1' }]
      )

      expect(subject.query_region('my-instance', conn)).to eq('us-east-1')
    end

    it 'returns nil when the query returns no results' do
      allow(dialect).to receive(:region_by_instance_id_query).and_return('SELECT region ...')
      allow(dialect).to receive(:execute_with_params).with(conn, 'SELECT region ...', ['unknown']).and_return([])

      expect(subject.query_region('unknown', conn)).to be_nil
    end

    it 'returns nil when the query returns nil' do
      allow(dialect).to receive(:region_by_instance_id_query).and_return('SELECT region ...')
      allow(dialect).to receive(:execute_with_params).with(conn, 'SELECT region ...', ['unknown']).and_return(nil)

      expect(subject.query_region('unknown', conn)).to be_nil
    end

    it 'returns nil when the region value is empty' do
      allow(dialect).to receive(:region_by_instance_id_query).and_return('SELECT region ...')
      allow(dialect).to receive(:execute_with_params).with(conn, 'SELECT region ...', ['instance-1']).and_return(
        [{ 'aws_region' => '' }]
      )

      expect(subject.query_region('instance-1', conn)).to be_nil
    end
  end

  describe '#parse_instance_templates' do
    let(:host_validator) { ->(_host) { true } }

    context 'with region-prefixed entries' do
      it 'parses [region]host:port format' do
        templates = subject.parse_instance_templates(
          '[us-east-1]?.xyz.us-east-1.rds.amazonaws.com:5432,[eu-west-1]?.xyz.eu-west-1.rds.amazonaws.com:3306',
          host_validator
        )

        expect(templates.size).to eq(2)
        expect(templates['us-east-1'].host).to eq('?.xyz.us-east-1.rds.amazonaws.com')
        expect(templates['us-east-1'].port).to eq(5432)
        expect(templates['eu-west-1'].host).to eq('?.xyz.eu-west-1.rds.amazonaws.com')
        expect(templates['eu-west-1'].port).to eq(3306)
      end

      it 'parses [region]host format without port' do
        templates = subject.parse_instance_templates(
          '[us-east-1]?.xyz.us-east-1.rds.amazonaws.com',
          host_validator
        )

        expect(templates.size).to eq(1)
        expect(templates['us-east-1'].host).to eq('?.xyz.us-east-1.rds.amazonaws.com')
        expect(templates['us-east-1'].port).to eq(AwsRubyDriverWrapper::Host::HostInfo::NO_PORT)
      end
    end

    context 'with region inferred from host' do
      it 'parses host patterns where region can be extracted from the URL' do
        templates = subject.parse_instance_templates(
          '?.xyz.us-east-1.rds.amazonaws.com:5432',
          host_validator
        )

        expect(templates.size).to eq(1)
        expect(templates['us-east-1']).not_to be_nil
        expect(templates['us-east-1'].host).to eq('?.xyz.us-east-1.rds.amazonaws.com')
        expect(templates['us-east-1'].port).to eq(5432)
      end
    end

    context 'with invalid entries' do
      it 'raises an error when region cannot be determined' do
        expect do
          subject.parse_instance_templates('?.custom-host.com:5432', host_validator)
        end.to raise_error(StandardError, /Unable to parse region/)
      end
    end
  end
end
