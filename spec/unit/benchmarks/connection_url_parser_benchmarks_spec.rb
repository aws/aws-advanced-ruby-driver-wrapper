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

# Guards the assumptions the connection URL parser benchmark relies on: that each benchmarked entry
# point exists, accepts the sample inputs, and parses the host, port, and database out of them. The
# benchmark itself is not run in CI, so drift in the parser's public API fails here instead of the
# benchmark silently breaking.
module AwsAdvancedRubyDriverWrapper
  RSpec.describe Utils::ConnectionConfigParser do
    let(:driver) { :postgresql }
    let(:single_host_url) { 'postgresql://my-cluster.cluster-XYZ.us-east-2.rds.amazonaws.com:5432/postgres' }
    let(:five_hosts) { (1..5).map { |i| "instance-#{i}.XYZ.us-east-2.rds.amazonaws.com:5432" }.join(',') }
    let(:five_hosts_url) { "postgresql://#{five_hosts}/postgres" }
    let(:url_with_properties) do
      "#{single_host_url}?user=someUser&password=somePassword&wrapper_plugins=failover" \
        '&connect_timeout=10&application_name=benchmark'
    end
    let(:conninfo) { 'host=my-cluster.cluster-XYZ.us-east-2.rds.amazonaws.com port=5432 dbname=postgres' }
    let(:conninfo_with_properties) { "#{conninfo} user=someUser password=somePassword connect_timeout=10" }
    let(:single_host_section) { 'my-cluster.cluster-XYZ.us-east-2.rds.amazonaws.com:5432' }
    let(:host_port_pair) { 'instance-1.XYZ.us-east-2.rds.amazonaws.com:5432' }

    it 'parses a single-host URL into host, port, and database' do
      config = described_class.parse_uri(driver, single_host_url)
      expect(config.original_host).to eq('my-cluster.cluster-XYZ.us-east-2.rds.amazonaws.com')
      expect(config.original_port).to eq('5432')
      expect(config.driver_props[:dbname]).to eq('postgres')
      expect(config).not_to be_multi_host_url
    end

    it 'parses a five-host URL into a comma-joined host list flagged as multi-host' do
      config = described_class.parse_uri(driver, five_hosts_url)
      expect(config.original_host.split(',').length).to eq(5)
      expect(config.original_port).to eq('5432,5432,5432,5432,5432')
      expect(config).to be_multi_host_url
    end

    it 'parses query-string properties into wrapper and driver props' do
      config = described_class.parse_uri(driver, url_with_properties)
      expect(config.driver_props[:user]).to eq('someUser')
      expect(config.driver_props[:application_name]).to eq('benchmark')
      expect(config.wrapper_props[:wrapper_plugins]).to eq('failover')
    end

    it 'parses a basic conninfo string into host, port, and database' do
      config = described_class.parse_conninfo(driver, conninfo)
      expect(config.original_host).to eq('my-cluster.cluster-XYZ.us-east-2.rds.amazonaws.com')
      expect(config.original_port).to eq('5432')
      expect(config.driver_props[:dbname]).to eq('postgres')
    end

    it 'parses conninfo properties into driver props' do
      config = described_class.parse_conninfo(driver, conninfo_with_properties)
      expect(config.driver_props[:user]).to eq('someUser')
      expect(config.driver_props[:connect_timeout]).to eq('10')
    end

    it 'splits a single host section into a HostInfo with host and port' do
      host_info = described_class.string_to_host_info(single_host_section)
      expect(host_info.host).to eq('my-cluster.cluster-XYZ.us-east-2.rds.amazonaws.com')
      expect(host_info.port).to eq('5432')
    end

    it 'splits a five-host section into a comma-joined HostInfo' do
      host_info = described_class.string_to_host_info(five_hosts)
      expect(host_info.host.split(',').length).to eq(5)
      expect(host_info.port).to eq('5432')
    end

    it 'splits a single host:port pair into host and port' do
      expect(described_class.host_port_from_uri(host_port_pair))
        .to eq(['instance-1.XYZ.us-east-2.rds.amazonaws.com', '5432'])
    end
  end
end
