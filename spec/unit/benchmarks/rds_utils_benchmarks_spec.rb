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

# Guards the assumptions the RdsUtils benchmark relies on: that each benchmarked method still exists
# and returns the classification or metadata the benchmark treats as the representative case for its
# host. The benchmark itself is not run in CI, so drift in RdsUtils' API or behaviour fails here
# instead of the benchmark silently measuring the wrong thing.
module AwsAdvancedRubyDriverWrapper
  module Utils
    RSpec.describe RdsUtils do
      subject(:utils) { described_class }

      let(:instance) { 'instance-1.XYZ.us-east-2.rds.amazonaws.com' }
      let(:writer_cluster) { 'my-cluster.cluster-XYZ.us-east-2.rds.amazonaws.com' }
      let(:reader_cluster) { 'my-cluster.cluster-ro-XYZ.us-east-2.rds.amazonaws.com' }
      let(:custom_cluster) { 'my-custom.cluster-custom-XYZ.us-east-2.rds.amazonaws.com' }
      let(:proxy) { 'my-proxy.proxy-XYZ.us-east-2.rds.amazonaws.com' }
      let(:non_rds) { 'my-database.example.com' }
      let(:ipv4) { '10.20.30.40' }

      before { utils.clear_cache }

      it 'classifies each representative host to its expected type' do
        expect(utils.identify_rds_type(instance)).to eq(RdsUrlType::RDS_INSTANCE)
        expect(utils.identify_rds_type(writer_cluster)).to eq(RdsUrlType::RDS_WRITER_CLUSTER)
        expect(utils.identify_rds_type(reader_cluster)).to eq(RdsUrlType::RDS_READER_CLUSTER)
        expect(utils.identify_rds_type(custom_cluster)).to eq(RdsUrlType::RDS_CUSTOM_CLUSTER)
        expect(utils.identify_rds_type(proxy)).to eq(RdsUrlType::RDS_PROXY)
        expect(utils.identify_rds_type(non_rds)).to eq(RdsUrlType::OTHER)
      end

      it 'classifies a fresh (uncached) host the same as its cached counterpart' do
        expect(utils.identify_rds_type('instance-99.XYZ.us-east-2.rds.amazonaws.com')).to eq(RdsUrlType::RDS_INSTANCE)
        expect(utils.identify_rds_type('host-99.example.com')).to eq(RdsUrlType::OTHER)
      end

      it 'extracts metadata from the representative hosts' do
        expect(utils.rds_region(instance)).to eq('us-east-2')
        # rds_host_id only returns an id for endpoints carrying a DNS-group prefix (cluster, proxy);
        # a plain instance has no prefix, so nil is expected.
        expect(utils.rds_host_id(instance)).to be_nil
        expect(utils.rds_host_id(writer_cluster)).to eq('my-cluster')
        expect(utils.rds_cluster_id(writer_cluster)).to eq('my-cluster')
        expect(utils.rds_instance_host_pattern(instance)).to eq('?.XYZ.us-east-2.rds.amazonaws.com')
      end

      it 'answers the cluster-DNS predicates' do
        expect(utils.writer_cluster_dns?(writer_cluster)).to be(true)
        expect(utils.reader_cluster_dns?(reader_cluster)).to be(true)
        expect(utils.writer_cluster_dns?(reader_cluster)).to be(false)
      end

      it 'recognises an IPv4 address' do
        expect(utils.ip?(ipv4)).to be(true)
        expect(utils.ip?(instance)).to be(false)
      end

      it 'evaluates the green-instance check without matching a plain instance' do
        expect(utils.green_instance?(instance)).to be(false)
        expect(utils.green_instance?('instance-1-green-abcdef.XYZ.us-east-2.rds.amazonaws.com')).to be(true)
      end

      it 'strips the port from a host:port string' do
        expect(utils.remove_port("#{instance}:5432")).to eq(instance)
      end
    end
  end
end
