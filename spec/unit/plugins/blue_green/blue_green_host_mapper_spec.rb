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
require 'aws_advanced_ruby_driver_wrapper/plugins/blue_green/host_mapper'
require 'aws_advanced_ruby_driver_wrapper/plugins/blue_green/interim_status'
require 'aws_advanced_ruby_driver_wrapper/plugins/blue_green/phase'
require 'aws_advanced_ruby_driver_wrapper/host/host_info'
require 'aws_advanced_ruby_driver_wrapper/host/host_role'
require 'aws_advanced_ruby_driver_wrapper/utils/rds_utils'

RSpec.describe AwsAdvancedRubyDriverWrapper::Plugins::BlueGreen::HostMapper do
  let(:bg) { AwsAdvancedRubyDriverWrapper::Plugins::BlueGreen }
  let(:host_role) { AwsAdvancedRubyDriverWrapper::Host::HostRole }
  let(:rds_utils) { AwsAdvancedRubyDriverWrapper::Utils::RdsUtils }

  # Use real RDS-format hostnames so RdsUtils pattern matching works correctly.
  let(:blue_writer)  { 'mydb-instance-1.abc123.us-east-1.rds.amazonaws.com' }
  let(:blue_reader)  { 'mydb-instance-2.abc123.us-east-1.rds.amazonaws.com' }
  let(:blue_cluster) { 'mydb.cluster-abc123.us-east-1.rds.amazonaws.com' }
  let(:blue_ro)      { 'mydb.cluster-ro-abc123.us-east-1.rds.amazonaws.com' }

  let(:green_writer)  { 'mydb-instance-1-green-xyz123.abc123.us-east-1.rds.amazonaws.com' }
  let(:green_reader)  { 'mydb-instance-2-green-xyz123.abc123.us-east-1.rds.amazonaws.com' }
  let(:green_cluster) { 'mydb-green-xyz123.cluster-abc123.us-east-1.rds.amazonaws.com' }
  let(:green_ro)      { 'mydb-green-xyz123.cluster-ro-abc123.us-east-1.rds.amazonaws.com' }

  before { rds_utils.clear_cache }

  def make_host(host, role)
    AwsAdvancedRubyDriverWrapper::Host::HostInfo.new(host: host, port: 3306, role: role)
  end

  def make_interim(writer_host, reader_host, host_names)
    topo = [make_host(writer_host, host_role::WRITER), make_host(reader_host, host_role::READER)]
    bg::InterimStatus.new(bg::Phase::CREATED, '1.0', 3306, topo, topo, {}, {}, Set[*host_names],
                          false, false, false)
  end

  let(:source_status) { make_interim(blue_writer, blue_reader, [blue_writer, blue_reader, blue_cluster, blue_ro]) }
  let(:target_status) { make_interim(green_writer, green_reader, [green_writer, green_reader, green_cluster, green_ro]) }

  subject(:mapper) { described_class.new }

  describe '#update — instance pairs' do
    before { mapper.update(source_status, target_status) }

    it 'pairs the blue writer with the green writer' do
      pair = mapper.corresponding_hosts[blue_writer]
      expect(pair).not_to be_nil
      expect(pair[1].host).to eq(green_writer)
    end

    it 'pairs the blue reader with the green reader' do
      pair = mapper.corresponding_hosts[blue_reader]
      expect(pair).not_to be_nil
      expect(pair[1].host).to eq(green_reader)
    end
  end

  describe '#update — cluster pairs' do
    before { mapper.update(source_status, target_status) }

    it 'pairs the blue writer cluster endpoint with the green writer cluster endpoint' do
      pair = mapper.corresponding_hosts[blue_cluster]
      expect(pair).not_to be_nil
      expect(pair[1].host).to eq(green_cluster)
    end

    it 'pairs the blue reader cluster endpoint with the green reader cluster endpoint' do
      pair = mapper.corresponding_hosts[blue_ro]
      expect(pair).not_to be_nil
      expect(pair[1].host).to eq(green_ro)
    end
  end

  describe '#update — clears stale pairs on each call' do
    it 'replaces old pairs when called again with nil' do
      mapper.update(source_status, target_status)
      expect(mapper.corresponding_hosts).not_to be_empty

      mapper.update(nil, nil)
      expect(mapper.corresponding_hosts).to be_empty
    end
  end

  describe '#merge_ips' do
    it 'stores IP addresses by host' do
      mapper.merge_ips(blue_writer => '10.0.0.1', blue_reader => '10.0.0.2')
      expect(mapper.host_ip_addresses[blue_writer]).to eq('10.0.0.1')
    end

    it 'merges without clearing existing entries' do
      mapper.merge_ips(blue_writer => '10.0.0.1')
      mapper.merge_ips(blue_reader => '10.0.0.2')
      expect(mapper.host_ip_addresses.size).to eq(2)
    end
  end

  describe '#register_role' do
    it 'stores the role for each host name (downcased)' do
      mapper.register_role([blue_writer.upcase, blue_reader], bg::Role::SOURCE)
      expect(mapper.role_by_host[blue_writer]).to eq(bg::Role::SOURCE)
      expect(mapper.role_by_host[blue_reader]).to eq(bg::Role::SOURCE)
    end
  end

  describe '#clear' do
    it 'empties all maps' do
      mapper.update(source_status, target_status)
      mapper.merge_ips(blue_writer => '10.0.0.1')
      mapper.register_role([blue_writer], bg::Role::SOURCE)
      mapper.clear
      expect(mapper.corresponding_hosts).to be_empty
      expect(mapper.host_ip_addresses).to be_empty
      expect(mapper.role_by_host).to be_empty
    end
  end

  describe 'with a single-instance cluster (no readers)' do
    let(:source_single) do
      topo = [make_host(blue_writer, host_role::WRITER)]
      bg::InterimStatus.new(bg::Phase::CREATED, '1.0', 3306, topo, topo, {}, {}, Set[blue_writer, blue_cluster], false, false, false)
    end
    let(:target_single) do
      topo = [make_host(green_writer, host_role::WRITER)]
      bg::InterimStatus.new(bg::Phase::CREATED, '1.0', 3306, topo, topo, {}, {}, Set[green_writer, green_cluster], false, false, false)
    end

    it 'still pairs the writer' do
      mapper.update(source_single, target_single)
      expect(mapper.corresponding_hosts[blue_writer][1].host).to eq(green_writer)
    end
  end
end
