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
require 'aws-sdk-rds'
require 'aws_advanced_ruby_driver_wrapper/utils/iam_auth_utils'
require 'aws_advanced_ruby_driver_wrapper/utils/rds_utils'
require 'aws_advanced_ruby_driver_wrapper/utils/rds_url_type'

RSpec.describe AwsAdvancedRubyDriverWrapper::Utils::IamAuthUtils do
  subject(:utils) { described_class }

  let(:rds_utils) { AwsAdvancedRubyDriverWrapper::Utils::RdsUtils }
  let(:rds_url_type) { AwsAdvancedRubyDriverWrapper::Utils::RdsUrlType }

  describe '.parse_token_expiry' do
    it 'returns the X-Amz-Expires integer when present' do
      token = 'myhost.us-east-1.rds.amazonaws.com/?X-Amz-Expires=900&X-Amz-Algorithm=AWS4-HMAC-SHA256'
      expect(utils.parse_token_expiry(token)).to eq 900
    end

    it 'returns nil when X-Amz-Expires is absent' do
      token = 'myhost.us-east-1.rds.amazonaws.com/?X-Amz-Algorithm=AWS4-HMAC-SHA256'
      expect(utils.parse_token_expiry(token)).to be_nil
    end

    it 'returns nil for a malformed token' do
      expect(utils.parse_token_expiry('not a valid token %%%')).to be_nil
    end

    it 'is case-insensitive for the key' do
      token = 'myhost.us-east-1.rds.amazonaws.com/?x-amz-expires=600'
      expect(utils.parse_token_expiry(token)).to eq 600
    end
  end

  describe '.build_token_entry' do
    let(:now) { 1_000_000.0 }

    before do
      allow(Process).to receive(:clock_gettime).with(Process::CLOCK_MONOTONIC).and_return(now)
    end

    it 'sets expires_at using parsed expiry minus buffer' do
      token = 'myhost/?X-Amz-Expires=900'
      entry = utils.build_token_entry(token, 870)
      expect(entry.expires_at).to be_within(0.001).of(now + 900 - described_class::EXPIRY_BUFFER_SEC)
    end

    it 'falls back to fallback_expiry_sec when parse returns nil' do
      token = 'myhost/?no-expiry=true'
      entry = utils.build_token_entry(token, 870)
      expect(entry.expires_at).to be_within(0.001).of(now + 870 - described_class::EXPIRY_BUFFER_SEC)
    end

    it 'returns a frozen TokenEntry' do
      entry = utils.build_token_entry('myhost/?X-Amz-Expires=900', 870)
      expect(entry).to be_a(described_class::TokenEntry)
      expect(entry).to be_frozen
    end

    it 'stores the token in the entry' do
      token = 'myhost/?X-Amz-Expires=900'
      entry = utils.build_token_entry(token, 870)
      expect(entry.token).to eq token
    end
  end

  describe '.valid_entry?' do
    it 'returns true for a valid TokenEntry within TTL' do
      entry = described_class::TokenEntry.new(
        token: 'tok',
        expires_at: Process.clock_gettime(Process::CLOCK_MONOTONIC) + 300
      )
      expect(utils.valid_entry?(entry)).to be true
    end

    it 'returns false for an expired TokenEntry' do
      entry = described_class::TokenEntry.new(
        token: 'tok',
        expires_at: Process.clock_gettime(Process::CLOCK_MONOTONIC) - 1
      )
      expect(utils.valid_entry?(entry)).to be false
    end

    it 'returns false for a plain string' do
      expect(utils.valid_entry?('some-token-string')).to be false
    end

    it 'returns false for nil' do
      expect(utils.valid_entry?(nil)).to be false
    end
  end

  describe '.region_for' do
    let(:credentials_provider) { double('credentials_provider') }

    context 'with an explicit :iam_region prop' do
      it 'returns the explicit region without calling RdsUtils' do
        expect(rds_utils).not_to receive(:rds_region)
        result = utils.region_for(
          host: 'any.host',
          props: { iam_region: 'eu-west-1' },
          rds_type: rds_url_type::RDS_WRITER_CLUSTER,
          credentials_provider:
        )
        expect(result).to eq 'eu-west-1'
      end

      it 'ignores an empty :iam_region and falls through' do
        allow(rds_utils).to receive(:rds_region).and_return('us-east-2')
        result = utils.region_for(
          host: 'db.cluster-XYZ.us-east-2.rds.amazonaws.com',
          props: { iam_region: '' },
          rds_type: rds_url_type::RDS_WRITER_CLUSTER,
          credentials_provider:
        )
        expect(result).to eq 'us-east-2'
      end
    end

    context 'with a non-global RDS hostname and no explicit region' do
      it 'returns the region from RdsUtils.rds_region' do
        host = 'db.cluster-XYZ.us-east-2.rds.amazonaws.com'
        result = utils.region_for(
          host:,
          props: {},
          rds_type: rds_url_type::RDS_WRITER_CLUSTER,
          credentials_provider:
        )
        expect(result).to eq 'us-east-2'
      end
    end

    context 'with a non-RDS hostname and no prop' do
      it 'returns nil' do
        result = utils.region_for(
          host: 'example.com',
          props: {},
          rds_type: rds_url_type::OTHER,
          credentials_provider:
        )
        expect(result).to be_nil
      end
    end

    context 'with a global DB rds_type' do
      it 'calls region_from_global_cluster and returns its result' do
        host = 'global-cluster-test-name.global-XYZ.global.rds.amazonaws.com'
        allow(utils).to receive(:region_from_global_cluster).with(host, credentials_provider, rds_client: nil).and_return('us-east-1')
        result = utils.region_for(
          host:,
          props: {},
          rds_type: rds_url_type::RDS_GLOBAL_WRITER_CLUSTER,
          credentials_provider:
        )
        expect(result).to eq 'us-east-1'
      end
    end
  end

  describe '.region_from_global_cluster' do
    let(:credentials_provider) { double('credentials_provider') }
    let(:host) { 'my-global-cluster.global-XYZ.global.rds.amazonaws.com' }

    let(:writer_member) do
      double('writer_member',
             is_writer: true,
             db_cluster_arn: 'arn:aws:rds:us-west-2:123456789012:cluster:my-cluster')
    end

    let(:reader_member) do
      double('reader_member', is_writer: false, db_cluster_arn: 'arn:aws:rds:eu-west-1:123456789012:cluster:my-cluster')
    end

    let(:global_cluster) { double('global_cluster', global_cluster_members: [reader_member, writer_member]) }
    let(:response) { double('response', global_clusters: [global_cluster]) }
    let(:rds_client) { instance_double(Aws::RDS::Client) }

    before do
      stub_const('Aws::RDS::Client', class_double(Aws::RDS::Client))
      allow(Aws::RDS::Client).to receive(:new).with(credentials: credentials_provider).and_return(rds_client)
      allow(rds_client).to receive(:describe_global_clusters).and_return(response)
    end

    it 'parses the region from the writer ARN' do
      result = utils.region_from_global_cluster(host, credentials_provider)
      expect(result).to eq 'us-west-2'
    end

    it 'parses the region from an aws-cn (China) writer ARN' do
      cn_writer = double('cn_writer', is_writer: true,
                                      db_cluster_arn: 'arn:aws-cn:rds:cn-north-1:123456789012:cluster:my-cluster')
      cn_cluster = double('cn_cluster', global_cluster_members: [cn_writer])
      allow(rds_client).to receive(:describe_global_clusters)
        .and_return(double('cn_response', global_clusters: [cn_cluster]))

      expect(utils.region_from_global_cluster(host, credentials_provider)).to eq 'cn-north-1'
    end

    it 'parses the region from an aws-us-gov (GovCloud) writer ARN' do
      gov_writer = double('gov_writer', is_writer: true,
                                        db_cluster_arn: 'arn:aws-us-gov:rds:us-gov-west-1:123456789012:cluster:my-cluster')
      gov_cluster = double('gov_cluster', global_cluster_members: [gov_writer])
      allow(rds_client).to receive(:describe_global_clusters)
        .and_return(double('gov_response', global_clusters: [gov_cluster]))

      expect(utils.region_from_global_cluster(host, credentials_provider)).to eq 'us-gov-west-1'
    end

    it 'returns nil when no writer member is found' do
      no_writer_cluster = double('no_writer_cluster', global_cluster_members: [reader_member])
      no_writer_response = double('no_writer_response', global_clusters: [no_writer_cluster])
      allow(rds_client).to receive(:describe_global_clusters).and_return(no_writer_response)

      expect(utils.region_from_global_cluster(host, credentials_provider)).to be_nil
    end
  end

  describe '.generate_token' do
    let(:credentials_provider) { double('credentials_provider') }
    let(:generator) { instance_double(Aws::RDS::AuthTokenGenerator) }

    before do
      stub_const('Aws::RDS::AuthTokenGenerator', class_double(Aws::RDS::AuthTokenGenerator))
      allow(Aws::RDS::AuthTokenGenerator).to receive(:new).with(credentials: credentials_provider).and_return(generator)
      allow(generator).to receive(:auth_token).and_return('generated-token')
    end

    it 'calls auth_token with correct arguments' do
      result = utils.generate_token(
        region: 'us-east-1',
        hostname: 'myhost.us-east-1.rds.amazonaws.com',
        port: 5432,
        user: 'dbuser',
        credentials_provider:
      )

      expect(generator).to have_received(:auth_token).with(
        region: 'us-east-1',
        endpoint: 'myhost.us-east-1.rds.amazonaws.com:5432',
        user_name: 'dbuser'
      )
      expect(result).to eq 'generated-token'
    end
  end

  describe '.resolve_host' do
    let(:host_info) { instance_double('AwsAdvancedRubyDriverWrapper::Utils::HostInfo', host: 'info.host.com') }

    it 'returns iam_host when non-nil and non-empty' do
      expect(utils.resolve_host('override.host.com', host_info)).to eq 'override.host.com'
    end

    it 'falls back to host_info.host when iam_host is nil' do
      expect(utils.resolve_host(nil, host_info)).to eq 'info.host.com'
    end

    it 'falls back to host_info.host when iam_host is empty' do
      expect(utils.resolve_host('', host_info)).to eq 'info.host.com'
    end
  end

  describe '.resolve_port' do
    let(:host_info) { instance_double('AwsAdvancedRubyDriverWrapper::Utils::HostInfo') }

    context 'when iam_default_port is positive' do
      it 'returns iam_default_port' do
        allow(host_info).to receive(:port_specified?).and_return(true)
        allow(host_info).to receive(:port).and_return(1234)
        expect(utils.resolve_port(9999, host_info, 5432)).to eq 9999
      end
    end

    context 'when iam_default_port is zero or nil' do
      it 'returns host_info.port when port_specified?' do
        allow(host_info).to receive(:port_specified?).and_return(true)
        allow(host_info).to receive(:port).and_return(3306)
        expect(utils.resolve_port(0, host_info, 5432)).to eq 3306
      end

      it 'returns dialect_default_port when port is not specified' do
        allow(host_info).to receive(:port_specified?).and_return(false)
        expect(utils.resolve_port(nil, host_info, 5432)).to eq 5432
      end
    end
  end

  describe '.cache_key' do
    it 'formats as region:host:port:user' do
      expect(utils.cache_key('us-east-1', 'myhost.rds.amazonaws.com', 5432, 'admin'))
        .to eq 'us-east-1:myhost.rds.amazonaws.com:5432:admin'
    end
  end
end
