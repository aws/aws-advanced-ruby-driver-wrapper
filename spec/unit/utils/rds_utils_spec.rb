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
require 'aws_advanced_ruby_wrapper/utils/rds_utils'
require 'aws_advanced_ruby_wrapper/utils/rds_url_type'

URL_TYPE = AwsAdvancedRubyWrapper::Utils::RdsUrlType

# Endpoint fixture table. Each entry defines a host and its expected properties.
# Adding a new region variant is a single entry here.
ENDPOINTS = [
  # -- US East (commercial) --
  { host: 'database-test-name.cluster-XYZ.us-east-2.rds.amazonaws.com',
    type: URL_TYPE::RDS_WRITER_CLUSTER, region: 'us-east-2', cluster_id: 'database-test-name',
    instance_id: nil, host_pattern: '?.XYZ.us-east-2.rds.amazonaws.com',
    rds_dns: true, cluster_url: 'database-test-name.cluster-XYZ.us-east-2.rds.amazonaws.com' },
  { host: 'database-test-name.cluster-XYZ.us-east-2.rds.amazonaws.com.',
    type: URL_TYPE::RDS_WRITER_CLUSTER, region: 'us-east-2', cluster_id: 'database-test-name',
    instance_id: nil, host_pattern: '?.XYZ.us-east-2.rds.amazonaws.com.',
    rds_dns: true, cluster_url: 'database-test-name.cluster-XYZ.us-east-2.rds.amazonaws.com.' },
  { host: 'database-test-name.cluster-ro-XYZ.us-east-2.rds.amazonaws.com',
    type: URL_TYPE::RDS_READER_CLUSTER, region: 'us-east-2', cluster_id: 'database-test-name',
    instance_id: nil, host_pattern: '?.XYZ.us-east-2.rds.amazonaws.com',
    rds_dns: true, cluster_url: 'database-test-name.cluster-XYZ.us-east-2.rds.amazonaws.com' },
  { host: 'instance-test-name.XYZ.us-east-2.rds.amazonaws.com',
    type: URL_TYPE::RDS_INSTANCE, region: 'us-east-2', cluster_id: nil,
    instance_id: 'instance-test-name', host_pattern: '?.XYZ.us-east-2.rds.amazonaws.com',
    rds_dns: true, cluster_url: nil },
  { host: 'proxy-test-name.proxy-XYZ.us-east-2.rds.amazonaws.com',
    type: URL_TYPE::RDS_PROXY, region: 'us-east-2', cluster_id: 'proxy-test-name',
    instance_id: nil, host_pattern: '?.XYZ.us-east-2.rds.amazonaws.com',
    rds_dns: true, cluster_url: nil },
  { host: 'endpoint-test-name.endpoint.proxy-XYZ.us-east-2.rds.amazonaws.com',
    type: URL_TYPE::RDS_PROXY_ENDPOINT, region: 'us-east-2', cluster_id: 'endpoint-test-name.endpoint',
    instance_id: nil, host_pattern: '?.XYZ.us-east-2.rds.amazonaws.com',
    rds_dns: true, cluster_url: nil },
  { host: 'custom-test-name.cluster-custom-XYZ.us-east-2.rds.amazonaws.com',
    type: URL_TYPE::RDS_CUSTOM_CLUSTER, region: 'us-east-2', cluster_id: 'custom-test-name',
    instance_id: nil, host_pattern: '?.XYZ.us-east-2.rds.amazonaws.com',
    rds_dns: true, cluster_url: nil },
  { host: 'database-test-name.shardgrp-XYZ.us-east-2.rds.amazonaws.com',
    type: URL_TYPE::RDS_AURORA_LIMITLESS_DB_SHARD_GROUP, region: 'us-east-2', cluster_id: 'database-test-name',
    instance_id: nil, host_pattern: '?.XYZ.us-east-2.rds.amazonaws.com',
    rds_dns: true, cluster_url: nil },

  # -- EU Redshift --
  { host: 'redshift-test-name.XYZ.eusc-de-east-1.rds.amazonaws.eu',
    type: URL_TYPE::RDS_INSTANCE, region: 'eusc-de-east-1', cluster_id: nil,
    instance_id: 'redshift-test-name', host_pattern: '?.XYZ.eusc-de-east-1.rds.amazonaws.eu',
    rds_dns: true, cluster_url: nil },

  # -- China (new) --
  { host: 'database-test-name.cluster-XYZ.rds.cn-northwest-1.amazonaws.com.cn',
    type: URL_TYPE::RDS_WRITER_CLUSTER, region: 'cn-northwest-1', cluster_id: 'database-test-name',
    instance_id: nil, host_pattern: '?.XYZ.rds.cn-northwest-1.amazonaws.com.cn',
    rds_dns: true, cluster_url: 'database-test-name.cluster-XYZ.rds.cn-northwest-1.amazonaws.com.cn' },
  { host: 'database-test-name.cluster-XYZ.rds.cn-northwest-1.amazonaws.com.cn.',
    type: URL_TYPE::RDS_WRITER_CLUSTER, region: 'cn-northwest-1', cluster_id: 'database-test-name',
    instance_id: nil, host_pattern: '?.XYZ.rds.cn-northwest-1.amazonaws.com.cn.',
    rds_dns: true, cluster_url: 'database-test-name.cluster-XYZ.rds.cn-northwest-1.amazonaws.com.cn.' },
  { host: 'database-test-name.cluster-ro-XYZ.rds.cn-northwest-1.amazonaws.com.cn',
    type: URL_TYPE::RDS_READER_CLUSTER, region: 'cn-northwest-1', cluster_id: 'database-test-name',
    instance_id: nil, host_pattern: '?.XYZ.rds.cn-northwest-1.amazonaws.com.cn',
    rds_dns: true, cluster_url: 'database-test-name.cluster-XYZ.rds.cn-northwest-1.amazonaws.com.cn' },
  { host: 'instance-test-name.XYZ.rds.cn-northwest-1.amazonaws.com.cn',
    type: URL_TYPE::RDS_INSTANCE, region: 'cn-northwest-1', cluster_id: nil,
    instance_id: 'instance-test-name', host_pattern: '?.XYZ.rds.cn-northwest-1.amazonaws.com.cn',
    rds_dns: true, cluster_url: nil },
  { host: 'proxy-test-name.proxy-XYZ.rds.cn-northwest-1.amazonaws.com.cn',
    type: URL_TYPE::RDS_PROXY, region: 'cn-northwest-1', cluster_id: 'proxy-test-name',
    instance_id: nil, host_pattern: '?.XYZ.rds.cn-northwest-1.amazonaws.com.cn',
    rds_dns: true, cluster_url: nil },
  { host: 'custom-test-name.cluster-custom-XYZ.rds.cn-northwest-1.amazonaws.com.cn',
    type: URL_TYPE::RDS_CUSTOM_CLUSTER, region: 'cn-northwest-1', cluster_id: 'custom-test-name',
    instance_id: nil, host_pattern: '?.XYZ.rds.cn-northwest-1.amazonaws.com.cn',
    rds_dns: true, cluster_url: nil },
  { host: 'database-test-name.shardgrp-XYZ.rds.cn-northwest-1.amazonaws.com.cn',
    type: URL_TYPE::RDS_AURORA_LIMITLESS_DB_SHARD_GROUP, region: 'cn-northwest-1', cluster_id: 'database-test-name',
    instance_id: nil, host_pattern: '?.XYZ.rds.cn-northwest-1.amazonaws.com.cn',
    rds_dns: true, cluster_url: nil },

  # -- China (old/legacy) --
  { host: 'database-test-name.cluster-XYZ.cn-northwest-1.rds.amazonaws.com.cn',
    type: URL_TYPE::RDS_WRITER_CLUSTER, region: 'cn-northwest-1', cluster_id: 'database-test-name',
    instance_id: nil, host_pattern: '?.XYZ.cn-northwest-1.rds.amazonaws.com.cn',
    rds_dns: true, cluster_url: 'database-test-name.cluster-XYZ.cn-northwest-1.rds.amazonaws.com.cn' },
  { host: 'database-test-name.cluster-XYZ.cn-northwest-1.rds.amazonaws.com.cn.',
    type: URL_TYPE::RDS_WRITER_CLUSTER, region: 'cn-northwest-1', cluster_id: 'database-test-name',
    instance_id: nil, host_pattern: '?.XYZ.cn-northwest-1.rds.amazonaws.com.cn.',
    rds_dns: true, cluster_url: 'database-test-name.cluster-XYZ.cn-northwest-1.rds.amazonaws.com.cn.' },
  { host: 'database-test-name.cluster-ro-XYZ.cn-northwest-1.rds.amazonaws.com.cn',
    type: URL_TYPE::RDS_READER_CLUSTER, region: 'cn-northwest-1', cluster_id: 'database-test-name',
    instance_id: nil, host_pattern: '?.XYZ.cn-northwest-1.rds.amazonaws.com.cn',
    rds_dns: true, cluster_url: 'database-test-name.cluster-XYZ.cn-northwest-1.rds.amazonaws.com.cn' },
  { host: 'instance-test-name.XYZ.cn-northwest-1.rds.amazonaws.com.cn',
    type: URL_TYPE::RDS_INSTANCE, region: 'cn-northwest-1', cluster_id: nil,
    instance_id: 'instance-test-name', host_pattern: '?.XYZ.cn-northwest-1.rds.amazonaws.com.cn',
    rds_dns: true, cluster_url: nil },
  { host: 'proxy-test-name.proxy-XYZ.cn-northwest-1.rds.amazonaws.com.cn',
    type: URL_TYPE::RDS_PROXY, region: 'cn-northwest-1', cluster_id: 'proxy-test-name',
    instance_id: nil, host_pattern: '?.XYZ.cn-northwest-1.rds.amazonaws.com.cn',
    rds_dns: true, cluster_url: nil },
  { host: 'custom-test-name.cluster-custom-XYZ.cn-northwest-1.rds.amazonaws.com.cn',
    type: URL_TYPE::RDS_CUSTOM_CLUSTER, region: 'cn-northwest-1', cluster_id: 'custom-test-name',
    instance_id: nil, host_pattern: '?.XYZ.cn-northwest-1.rds.amazonaws.com.cn',
    rds_dns: true, cluster_url: nil },
  { host: 'database-test-name.shardgrp-XYZ.cn-northwest-1.rds.amazonaws.com.cn',
    type: URL_TYPE::RDS_AURORA_LIMITLESS_DB_SHARD_GROUP, region: 'cn-northwest-1', cluster_id: 'database-test-name',
    instance_id: nil, host_pattern: '?.XYZ.cn-northwest-1.rds.amazonaws.com.cn',
    rds_dns: true, cluster_url: nil },
  { host: 'database-test-name.shardgrp-XYZ.cn-northwest-1.rds.amazonaws.com.cn.',
    type: URL_TYPE::RDS_AURORA_LIMITLESS_DB_SHARD_GROUP, region: 'cn-northwest-1', cluster_id: 'database-test-name',
    instance_id: nil, host_pattern: '?.XYZ.cn-northwest-1.rds.amazonaws.com.cn.',
    rds_dns: true, cluster_url: 'database-test-name.shardgrp-XYZ.cn-northwest-1.rds.amazonaws.com.cn.' },

  # -- Gov --
  { host: 'database-test-name.cluster-XYZ.rds.us-gov-east-1.amazonaws.com',
    type: URL_TYPE::RDS_WRITER_CLUSTER, region: 'us-gov-east-1', cluster_id: 'database-test-name',
    instance_id: nil, host_pattern: '?.XYZ.rds.us-gov-east-1.amazonaws.com',
    rds_dns: true, cluster_url: 'database-test-name.cluster-XYZ.rds.us-gov-east-1.amazonaws.com' },

  # -- ISO --
  { host: 'database-test-name.cluster-XYZ.rds.us-iso-east-1.c2s.ic.gov',
    type: URL_TYPE::RDS_WRITER_CLUSTER, region: 'us-iso-east-1', cluster_id: 'database-test-name',
    instance_id: nil, host_pattern: '?.XYZ.rds.us-iso-east-1.c2s.ic.gov',
    rds_dns: true, cluster_url: 'database-test-name.cluster-XYZ.rds.us-iso-east-1.c2s.ic.gov' },
  { host: 'database-test-name.cluster-XYZ.rds.us-iso-east-1.c2s.ic.gov.',
    type: URL_TYPE::RDS_WRITER_CLUSTER, region: 'us-iso-east-1', cluster_id: 'database-test-name',
    instance_id: nil, host_pattern: '?.XYZ.rds.us-iso-east-1.c2s.ic.gov.',
    rds_dns: true, cluster_url: 'database-test-name.cluster-XYZ.rds.us-iso-east-1.c2s.ic.gov.' },
  { host: 'database-test-name.cluster-ro-XYZ.rds.us-iso-east-1.c2s.ic.gov',
    type: URL_TYPE::RDS_READER_CLUSTER, region: 'us-iso-east-1', cluster_id: 'database-test-name',
    instance_id: nil, host_pattern: '?.XYZ.rds.us-iso-east-1.c2s.ic.gov',
    rds_dns: true, cluster_url: 'database-test-name.cluster-XYZ.rds.us-iso-east-1.c2s.ic.gov' },
  { host: 'instance-test-name.XYZ.rds.us-iso-east-1.c2s.ic.gov',
    type: URL_TYPE::RDS_INSTANCE, region: 'us-iso-east-1', cluster_id: nil,
    instance_id: 'instance-test-name', host_pattern: '?.XYZ.rds.us-iso-east-1.c2s.ic.gov',
    rds_dns: true, cluster_url: nil },
  { host: 'proxy-test-name.proxy-XYZ.rds.us-iso-east-1.c2s.ic.gov',
    type: URL_TYPE::RDS_PROXY, region: 'us-iso-east-1', cluster_id: 'proxy-test-name',
    instance_id: nil, host_pattern: '?.XYZ.rds.us-iso-east-1.c2s.ic.gov',
    rds_dns: true, cluster_url: nil },
  { host: 'custom-test-name.cluster-custom-XYZ.rds.us-iso-east-1.c2s.ic.gov',
    type: URL_TYPE::RDS_CUSTOM_CLUSTER, region: 'us-iso-east-1', cluster_id: 'custom-test-name',
    instance_id: nil, host_pattern: '?.XYZ.rds.us-iso-east-1.c2s.ic.gov',
    rds_dns: true, cluster_url: nil },
  { host: 'database-test-name.shardgrp-XYZ.rds.us-iso-east-1.c2s.ic.gov',
    type: URL_TYPE::RDS_AURORA_LIMITLESS_DB_SHARD_GROUP, region: 'us-iso-east-1', cluster_id: 'database-test-name',
    instance_id: nil, host_pattern: '?.XYZ.rds.us-iso-east-1.c2s.ic.gov',
    rds_dns: true, cluster_url: nil },

  # -- ISOB --
  { host: 'database-test-name.cluster-XYZ.rds.us-isob-east-1.sc2s.sgov.gov',
    type: URL_TYPE::RDS_WRITER_CLUSTER, region: 'us-isob-east-1', cluster_id: 'database-test-name',
    instance_id: nil, host_pattern: '?.XYZ.rds.us-isob-east-1.sc2s.sgov.gov',
    rds_dns: true, cluster_url: 'database-test-name.cluster-XYZ.rds.us-isob-east-1.sc2s.sgov.gov' },
  { host: 'database-test-name.cluster-ro-XYZ.rds.us-isob-east-1.sc2s.sgov.gov',
    type: URL_TYPE::RDS_READER_CLUSTER, region: 'us-isob-east-1', cluster_id: 'database-test-name',
    instance_id: nil, host_pattern: '?.XYZ.rds.us-isob-east-1.sc2s.sgov.gov',
    rds_dns: true, cluster_url: 'database-test-name.cluster-XYZ.rds.us-isob-east-1.sc2s.sgov.gov' },
  { host: 'instance-test-name.XYZ.rds.us-isob-east-1.sc2s.sgov.gov',
    type: URL_TYPE::RDS_INSTANCE, region: 'us-isob-east-1', cluster_id: nil,
    instance_id: 'instance-test-name', host_pattern: '?.XYZ.rds.us-isob-east-1.sc2s.sgov.gov',
    rds_dns: true, cluster_url: nil },
  { host: 'proxy-test-name.proxy-XYZ.rds.us-isob-east-1.sc2s.sgov.gov',
    type: URL_TYPE::RDS_PROXY, region: 'us-isob-east-1', cluster_id: 'proxy-test-name',
    instance_id: nil, host_pattern: '?.XYZ.rds.us-isob-east-1.sc2s.sgov.gov',
    rds_dns: true, cluster_url: nil },
  { host: 'custom-test-name.cluster-custom-XYZ.rds.us-isob-east-1.sc2s.sgov.gov',
    type: URL_TYPE::RDS_CUSTOM_CLUSTER, region: 'us-isob-east-1', cluster_id: 'custom-test-name',
    instance_id: nil, host_pattern: '?.XYZ.rds.us-isob-east-1.sc2s.sgov.gov',
    rds_dns: true, cluster_url: nil },
  { host: 'database-test-name.shardgrp-XYZ.rds.us-isob-east-1.sc2s.sgov.gov',
    type: URL_TYPE::RDS_AURORA_LIMITLESS_DB_SHARD_GROUP, region: 'us-isob-east-1', cluster_id: 'database-test-name',
    instance_id: nil, host_pattern: '?.XYZ.rds.us-isob-east-1.sc2s.sgov.gov',
    rds_dns: true, cluster_url: nil },

  # -- Global DB --
  { host: 'global-cluster-test-name.global-XYZ.global.rds.amazonaws.com',
    type: URL_TYPE::RDS_GLOBAL_WRITER_CLUSTER, region: nil, cluster_id: nil,
    instance_id: nil, host_pattern: nil,
    rds_dns: false, cluster_url: nil },

  # -- ELB --
  { host: 'elb-name.elb.us-east-2.amazonaws.com',
    type: :elb, region: 'us-east-2', cluster_id: nil,
    instance_id: nil, host_pattern: nil,
    rds_dns: false, cluster_url: nil },
  { host: 'elb-name.elb.us-east-2.amazonaws.com.',
    type: :elb, region: nil, cluster_id: nil,
    instance_id: nil, host_pattern: nil,
    rds_dns: false, cluster_url: nil },

  # -- Broken China paths --
  { host: 'database-test-name.cluster-XYZ.rds.cn-northwest-1.rds.amazonaws.com.cn',
    type: URL_TYPE::RDS_INSTANCE, region: 'cn-northwest-1', cluster_id: nil,
    instance_id: 'database-test-name.cluster-XYZ', host_pattern: '?.rds.cn-northwest-1.rds.amazonaws.com.cn',
    rds_dns: true, cluster_url: nil },
  { host: 'database-test-name.cluster-XYZ.rds.cn-northwest-1.amazonaws.com',
    type: URL_TYPE::RDS_WRITER_CLUSTER, region: 'cn-northwest-1', cluster_id: 'database-test-name',
    instance_id: nil, host_pattern: '?.XYZ.rds.cn-northwest-1.amazonaws.com',
    rds_dns: true, cluster_url: nil },
  { host: 'database-test-name.cluster-XYZ.rds.amazonaws.com.cn',
    type: :broken, region: nil, cluster_id: nil,
    instance_id: nil, host_pattern: nil,
    rds_dns: false, cluster_url: nil }
].freeze

PREDICATES = {
  rds_instance?: [URL_TYPE::RDS_INSTANCE],
  rds_cluster_dns?: [URL_TYPE::RDS_WRITER_CLUSTER, URL_TYPE::RDS_READER_CLUSTER],
  writer_cluster_dns?: [URL_TYPE::RDS_WRITER_CLUSTER],
  reader_cluster_dns?: [URL_TYPE::RDS_READER_CLUSTER],
  limitless_db_shard_group_dns?: [URL_TYPE::RDS_AURORA_LIMITLESS_DB_SHARD_GROUP]
}.freeze

METADATA_METHODS = {
  rds_host_id: :cluster_id,
  rds_instance_id: :instance_id,
  rds_instance_host_pattern: :host_pattern
}.freeze

RSpec.describe AwsAdvancedRubyWrapper::Utils::RdsUtils do
  subject(:utils) { described_class }

  let(:url_type) { URL_TYPE }

  before { utils.clear_cache }

  describe '.rds_dns?' do
    ENDPOINTS.each do |ep|
      it "returns #{ep[:rds_dns]} for #{ep[:host]}" do
        expect(utils.rds_dns?(ep[:host])).to be(ep[:rds_dns])
      end
    end

    it 'returns false for nil and empty' do
      expect(utils.rds_dns?(nil)).to be false
      expect(utils.rds_dns?('')).to be false
    end
  end

  PREDICATES.each do |method, true_types|
    describe ".#{method}" do
      ENDPOINTS.select { |ep| ep[:rds_dns] }.each do |ep|
        expected = true_types.include?(ep[:type])
        it "returns #{expected} for #{ep[:host]}" do
          expect(utils.public_send(method, ep[:host])).to be(expected)
        end
      end
    end
  end

  describe '.global_db_writer_cluster_dns?' do
    it 'returns true for global DB writer cluster' do
      global = ENDPOINTS.find { |ep| ep[:type] == URL_TYPE::RDS_GLOBAL_WRITER_CLUSTER }
      expect(utils.global_db_writer_cluster_dns?(global[:host])).to be true
    end

    it 'returns false for regular clusters' do
      ep = ENDPOINTS.find { |ep| ep[:type] == URL_TYPE::RDS_WRITER_CLUSTER }
      expect(utils.global_db_writer_cluster_dns?(ep[:host])).to be false
    end
  end

  describe '.rds_proxy_endpoint_dns?' do
    it 'returns true for proxy endpoint' do
      ep = ENDPOINTS.find { |ep| ep[:type] == URL_TYPE::RDS_PROXY_ENDPOINT }
      expect(utils.rds_proxy_endpoint_dns?(ep[:host])).to be true
    end

    it 'returns false for regular proxy' do
      ep = ENDPOINTS.find { |ep| ep[:type] == URL_TYPE::RDS_PROXY }
      expect(utils.rds_proxy_endpoint_dns?(ep[:host])).to be false
    end

    it 'returns false for nil and empty' do
      expect(utils.rds_proxy_endpoint_dns?(nil)).to be false
      expect(utils.rds_proxy_endpoint_dns?('')).to be false
    end
  end

  describe '.identify_rds_type' do
    ENDPOINTS.each do |ep|
      next if ep[:type].is_a?(Symbol)

      it "identifies #{ep[:host]} as #{ep[:type]}" do
        expect(utils.identify_rds_type(ep[:host])).to eq ep[:type]
      end
    end

    it 'identifies IP addresses' do
      expect(utils.identify_rds_type('192.168.1.1'))
        .to eq url_type::IP_ADDRESS
      expect(utils.identify_rds_type('2001:0db8:85a3:0000:0000:8a2e:0370:7334'))
        .to eq url_type::IP_ADDRESS
    end

    it 'returns OTHER for non-RDS hosts' do
      expect(utils.identify_rds_type('example.com')).to eq url_type::OTHER
      expect(utils.identify_rds_type(nil)).to eq url_type::OTHER
      expect(utils.identify_rds_type('')).to eq url_type::OTHER
    end
  end

  METADATA_METHODS.each do |method, key|
    describe ".#{method}" do
      ENDPOINTS.select { |ep| ep[:rds_dns] }.each do |ep|
        it "returns #{ep[key].inspect} for #{ep[:host]}" do
          expect(utils.public_send(method, ep[:host])).to eq ep[key]
        end
      end

      it 'returns nil for nil and empty' do
        expect(utils.public_send(method, nil)).to be_nil
        expect(utils.public_send(method, '')).to be_nil
      end
    end
  end

  describe '.rds_region' do
    ENDPOINTS.each do |ep|
      next if ep[:region].nil?

      it "returns #{ep[:region]} for #{ep[:host]}" do
        expect(utils.rds_region(ep[:host])).to eq ep[:region]
      end
    end

    it 'returns nil for unrecognized hosts' do
      expect(utils.rds_region('example.com')).to be_nil
      expect(utils.rds_region(nil)).to be_nil
      expect(utils.rds_region('')).to be_nil
    end
  end

  describe '.same_region?' do
    it 'returns true for hosts in the same region' do
      us_east = ENDPOINTS.select { |ep| ep[:region] == 'us-east-2' }
      expect(utils.same_region?(us_east[0][:host], us_east[1][:host]))
        .to be true
    end

    it 'returns false for hosts in different regions' do
      us = ENDPOINTS.find { |ep| ep[:region] == 'us-east-2' }
      cn = ENDPOINTS.find { |ep| ep[:region] == 'cn-northwest-1' }
      expect(utils.same_region?(us[:host], cn[:host])).to be false
    end

    it 'returns false when either is nil or empty' do
      host = ENDPOINTS.first[:host]
      expect(utils.same_region?(nil, host)).to be false
      expect(utils.same_region?(host, nil)).to be false
      expect(utils.same_region?('', host)).to be false
    end
  end

  describe '.rds_cluster_host_url' do
    ENDPOINTS.each do |ep|
      next if ep[:cluster_url].nil?

      it "returns writer cluster URL for #{ep[:host]}" do
        expect(utils.rds_cluster_host_url(ep[:host]))
          .to eq ep[:cluster_url]
      end
    end

    it 'returns nil for non-cluster hosts' do
      expect(utils.rds_cluster_host_url('example.com')).to be_nil
      expect(utils.rds_cluster_host_url(nil)).to be_nil
      expect(utils.rds_cluster_host_url('')).to be_nil
    end
  end

  describe '.ip?' do
    it('detects IPv4') { expect(utils.ip?('192.168.1.1')).to be true }
    it('detects IPv6') { expect(utils.ip?('2001:0db8:85a3:0000:0000:8a2e:0370:7334')).to be true }
    it('rejects hostnames') { expect(utils.ip?('example.com')).to be false }
    it('rejects nil') { expect(utils.ip?(nil)).to be false }
    it('rejects empty') { expect(utils.ip?('')).to be false }
  end

  describe '.ipv4?' do
    it('matches valid') { expect(utils.ipv4?('10.0.0.1')).to be true }
    it('rejects leading zero') { expect(utils.ipv4?('01.0.0.1')).to be false }
    it('rejects out of range') { expect(utils.ipv4?('256.0.0.1')).to be false }
    it('rejects partial') { expect(utils.ipv4?('192.168.1')).to be false }
  end

  describe '.ipv6?' do
    it('matches full') { expect(utils.ipv6?('2001:0db8:85a3:0000:0000:8a2e:0370:7334')).to be true }
    it('matches compressed') { expect(utils.ipv6?('::1')).to be true }
    it('matches middle ::') { expect(utils.ipv6?('2001:db8::1')).to be true }
    it('rejects invalid') { expect(utils.ipv6?('not-ipv6')).to be false }
  end

  describe '.dns_pattern_valid?' do
    it('true with ?') { expect(utils.dns_pattern_valid?('?.example.com')).to be true }
    it('false without ?') { expect(utils.dns_pattern_valid?('example.com')).to be false }
  end

  describe '.remove_port' do
    it('strips port') { expect(utils.remove_port('host:3306')).to eq 'host' }
    it('no port unchanged') { expect(utils.remove_port('host')).to eq 'host' }
    it('handles nil') { expect(utils.remove_port(nil)).to be_nil }
    it('handles empty') { expect(utils.remove_port('')).to eq '' }
  end

  describe '.green_instance?' do
    it 'matches green instances' do
      expect(utils.green_instance?('test-instance-green-abcdef.domain.com')).to be true
      expect(utils.green_instance?('test-instance-green-abcdef-12345-green-000000.domain.com')).to be true
    end

    it 'rejects non-green patterns' do
      %w[
        test-instance
        test-instance-green-12345
        test-instance-green-123456
        test-instance.domain.com
        test-instance-green.domain.com
        test-instance-green-1.domain.com
        test-instance-green-12345.domain.com
        test-instance-green-abcdef-.domain.com
        test-instance-green-abcdef-12345.domain.com
        test-instance-green-abcdef-12345-green.domain.com
        test-instance-green-abcdef-12345-green-00000.domain.com
      ].each do |host|
        expect(utils.green_instance?(host)).to be(false), "expected false for #{host}"
      end
    end

    it('rejects nil') { expect(utils.green_instance?(nil)).to be false }
  end

  describe '.old_instance?' do
    it('matches old') { expect(utils.old_instance?('test-instance-old1.domain.com')).to be true }
    it('rejects non-old') { expect(utils.old_instance?('test-instance.domain.com')).to be false }
  end

  describe '.not_old_instance?' do
    it('true for non-old') { expect(utils.not_old_instance?('test-instance.domain.com')).to be true }
    it('false for old') { expect(utils.not_old_instance?('test-instance-old1.domain.com')).to be false }
    it('true for nil') { expect(utils.not_old_instance?(nil)).to be true }
    it('true for empty') { expect(utils.not_old_instance?('')).to be true }
  end

  describe '.not_green_and_old_prefix_instance?' do
    it 'returns true for normal hosts' do
      %w[
        test-instance.domain.com
        test-instance-green.domain.com
        test-instance-green-1.domain.com
        test-instance-green-12345.domain.com
        test-instance-green-abcdef-.domain.com
        test-instance-green-abcdef-12345.domain.com
        test-instance-green-abcdef-12345-green.domain.com
        test-instance-green-abcdef-12345-green-00000.domain.com
      ].each do |host|
        expect(utils.not_green_and_old_prefix_instance?(host))
          .to be(true), "expected true for #{host}"
      end
    end

    it 'returns false for green and old hosts' do
      expect(utils.not_green_and_old_prefix_instance?('test-instance-green-abcdef.domain.com'))
        .to be false
      expect(utils.not_green_and_old_prefix_instance?('test-instance-green-abcdef-12345-green-000000.domain.com'))
        .to be false
    end

    it('returns false for nil') { expect(utils.not_green_and_old_prefix_instance?(nil)).to be false }
  end

  describe '.remove_green_instance_prefix' do
    {
      'test-instance-green-123456.domain.com' => 'test-instance.domain.com',
      'test-instance-green-abcdef.domain.com' => 'test-instance.domain.com',
      'test-instance-green-abcdef' => 'test-instance',
      'test-instance-green-abcdef-12345-green-000000.domain.com' => 'test-instance-green-abcdef-12345.domain.com',
      'test-instance-green-123456-green-123456.domain.com' => 'test-instance-green-123456.domain.com'
    }.each do |input, expected|
      it "strips prefix: #{input}" do
        expect(utils.remove_green_instance_prefix(input))
          .to eq expected
      end
    end

    it 'returns unchanged for non-green hosts' do
      %w[
        test-instance
        test-instance.domain.com
        test-instance-green.domain.com
        test-instance-green-1.domain.com
        test-instance-green-1234.domain.com
        test-instance-green-12345.domain.com
        test-instance-green-abcdef-.domain.com
        test-instance-green-abcdef-12345.domain.com
        test-instance-green-abcdef-12345-green.domain.com
        test-instance-green-abcdef-12345-green-0000.domain.com
        test-instance-green-abcdef-12345-green-00000.domain.com
      ].each do |host|
        expect(utils.remove_green_instance_prefix(host))
          .to eq(host), "expected unchanged for #{host}"
      end
    end

    it('returns nil for nil') { expect(utils.remove_green_instance_prefix(nil)).to be_nil }
    it('returns empty for empty') { expect(utils.remove_green_instance_prefix('')).to eq '' }
  end

  describe 'prepare_host_func' do
    let(:suffix) { '.proxied' }
    let(:us_cluster) { ENDPOINTS.first[:host] }
    let(:us_cluster_dot) { ENDPOINTS[1][:host] }
    let(:us_reader) { ENDPOINTS.find { |ep| ep[:type] == URL_TYPE::RDS_READER_CLUSTER }[:host] }
    let(:us_limitless) { ENDPOINTS.find { |ep| ep[:type] == URL_TYPE::RDS_AURORA_LIMITLESS_DB_SHARD_GROUP }[:host] }

    after { utils.reset_prepare_host_func }

    it 'methods fail without func on suffixed hosts' do
      expect(utils.rds_dns?("#{us_cluster}#{suffix}")).to be false
      expect(utils.rds_cluster_dns?("#{us_cluster}#{suffix}")).to be false
      expect(utils.writer_cluster_dns?("#{us_cluster}#{suffix}")).to be false
      expect(utils.reader_cluster_dns?("#{us_reader}#{suffix}")).to be false
      expect(utils.limitless_db_shard_group_dns?("#{us_limitless}#{suffix}")).to be false
      expect(utils.rds_cluster_host_url("#{us_cluster}#{suffix}")).to be_nil
      expect(utils.rds_instance_host_pattern("#{us_cluster}#{suffix}")).to be_nil
      expect(utils.rds_region("#{us_cluster}#{suffix}")).to be_nil
    end

    it 'methods work with func set' do
      utils.prepare_host_func = ->(host) { host.delete_suffix(suffix) }
      utils.clear_cache

      expect(utils.rds_dns?("#{us_cluster}#{suffix}")).to be true
      expect(utils.rds_cluster_dns?("#{us_cluster}#{suffix}")).to be true
      expect(utils.writer_cluster_dns?("#{us_cluster}#{suffix}")).to be true
      expect(utils.reader_cluster_dns?("#{us_reader}#{suffix}")).to be true
      expect(utils.limitless_db_shard_group_dns?("#{us_limitless}#{suffix}")).to be true
      expect(utils.rds_cluster_host_url("#{us_cluster}#{suffix}")).to eq us_cluster
      expect(utils.rds_cluster_host_url("#{us_cluster_dot}#{suffix}")).to eq us_cluster_dot
      expect(utils.rds_region("#{us_cluster}#{suffix}")).to eq 'us-east-2'
    end

    it 'methods revert after reset' do
      utils.prepare_host_func = ->(host) { host.delete_suffix(suffix) }
      utils.clear_cache
      expect(utils.rds_dns?("#{us_cluster}#{suffix}")).to be true

      utils.reset_prepare_host_func
      utils.clear_cache
      expect(utils.rds_dns?("#{us_cluster}#{suffix}")).to be false
    end
  end

  # -- Caching --

  describe 'caching' do
    it 'returns consistent results on repeated calls' do
      host = ENDPOINTS.first[:host]
      3.times do
        expect(utils.rds_dns?(host)).to be true
        expect(utils.rds_region(host)).to eq ENDPOINTS.first[:region]
        expect(utils.rds_host_id(host)).to eq ENDPOINTS.first[:cluster_id]
      end
    end

    it 'clear_cache resets state' do
      host = ENDPOINTS.first[:host]
      expect(utils.rds_dns?(host)).to be true
      utils.clear_cache
      expect(utils.rds_dns?(host)).to be true
    end
  end
end

RSpec.describe AwsAdvancedRubyWrapper::Utils::RdsUrlType do
  let(:url_type) { described_class }

  it 'has correct attributes' do
    expect(url_type::RDS_WRITER_CLUSTER.rds?).to be true
    expect(url_type::RDS_WRITER_CLUSTER.rds_cluster?).to be true
    expect(url_type::RDS_WRITER_CLUSTER.has_region?).to be true

    expect(url_type::IP_ADDRESS.rds?).to be false
    expect(url_type::IP_ADDRESS.rds_cluster?).to be false
    expect(url_type::IP_ADDRESS.has_region?).to be false

    expect(url_type::RDS_PROXY.rds?).to be true
    expect(url_type::RDS_PROXY.rds_cluster?).to be false
    expect(url_type::RDS_PROXY.has_region?).to be true

    expect(url_type::RDS_GLOBAL_WRITER_CLUSTER.rds?).to be true
    expect(url_type::RDS_GLOBAL_WRITER_CLUSTER.rds_cluster?).to be true
    expect(url_type::RDS_GLOBAL_WRITER_CLUSTER.has_region?).to be false

    expect(url_type::OTHER.rds?).to be false
    expect(url_type::OTHER.rds_cluster?).to be false
    expect(url_type::OTHER.has_region?).to be false
  end

  it 'instances are frozen' do
    expect(url_type::RDS_WRITER_CLUSTER).to be_frozen
    expect(url_type::OTHER).to be_frozen
  end

  it 'works with == comparison' do
    type = url_type::RDS_WRITER_CLUSTER
    expect(type).to eq url_type::RDS_WRITER_CLUSTER
    expect(type).not_to eq url_type::RDS_READER_CLUSTER
  end

  it 'works with case/when' do
    result = case url_type::RDS_INSTANCE
             when url_type::RDS_WRITER_CLUSTER then :writer
             when url_type::RDS_INSTANCE then :instance
             else :other
             end
    expect(result).to eq :instance
  end

  it 'has a string representation' do
    expect(url_type::RDS_WRITER_CLUSTER.to_s).to eq 'rds_writer_cluster'
    expect(url_type::OTHER.to_s).to eq 'other'
  end
end
