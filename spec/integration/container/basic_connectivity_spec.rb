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

require_relative 'integration_helper'
require_relative 'utils/test_environment'
require_relative 'utils/test_environment_features'
require_relative 'utils/test_driver'
require_relative 'utils/driver_helper'
require_relative 'utils/proxy_helper'
require_relative 'utils/connection_utils'
require 'aws_advanced_ruby_driver_wrapper'
require 'timeout'

RSpec.describe 'BasicConnectivity', :integration,
               disable_on_features: [Integration::TestEnvironmentFeatures::PERFORMANCE] do
  # TODO: telemetry properties are not yet implemented in the Ruby wrapper
  let(:wrapper_props) { base_wrapper_props }

  def query_one(conn)
    result = Integration::DriverHelper.execute(drv, conn, 'SELECT 1 AS val')
    result.first['val'].to_i
  end

  def valid_conn?(conn)
    Timeout.timeout(10) { query_one(conn) == 1 }
  rescue StandardError
    false
  end

  before do
    skip 'No allowed drivers for this environment' if drv.nil?
  end

  it 'direct connection' do
    conn = Integration::DriverHelper.native_connect(drv, **base_config)
    expect(query_one(conn)).to eq(1)
  ensure
    Integration::DriverHelper.close(drv, conn) if conn
  end

  it 'wrapper connection' do
    conn = Integration::DriverHelper.wrapper_connect(drv, **base_config, **wrapper_props)
    expect(query_one(conn)).to eq(1)
  ensure
    Integration::DriverHelper.close(drv, conn) if conn
  end

  it 'proxied direct connection',
     features: [Integration::TestEnvironmentFeatures::NETWORK_OUTAGES_ENABLED] do
    proxy_instance = env.proxy_database_info.instances.first
    conn = Integration::DriverHelper.native_connect(drv, **proxy_config)
    expect(query_one(conn)).to eq(1)

    Integration::ProxyHelper.disable_connectivity(proxy_instance.instance_id)
    expect(valid_conn?(conn)).to be false
  ensure
    Integration::ProxyHelper.enable_connectivity(proxy_instance.instance_id) if proxy_instance
    Integration::DriverHelper.close(drv, conn) if conn
  end

  it 'proxied wrapper connection',
     features: [Integration::TestEnvironmentFeatures::NETWORK_OUTAGES_ENABLED] do
    proxy_instance = env.proxy_database_info.instances.first
    conn = Integration::DriverHelper.wrapper_connect(drv, **proxy_config, **wrapper_props)
    expect(query_one(conn)).to eq(1)

    Integration::ProxyHelper.disable_connectivity(proxy_instance.instance_id)
    expect(valid_conn?(conn)).to be false
  ensure
    Integration::ProxyHelper.enable_connectivity(proxy_instance.instance_id) if proxy_instance
    Integration::DriverHelper.close(drv, conn) if conn
  end

  it 'open wrapper connection without explicit port' do
    config = Integration::DriverHelper.native_config(
      drv,
      host: writer.host,
      port: nil,
      user: info.username,
      password: info.password,
      dbname: info.default_dbname
    )
    conn = Integration::DriverHelper.wrapper_connect(drv, **config, **wrapper_props)
    expect(conn).not_to be_nil
    expect(query_one(conn)).to eq(1)
  ensure
    Integration::DriverHelper.close(drv, conn) if conn
  end

  context 'failed connections' do
    it 'raises when database name is incorrect' do
      bad_config = Integration::DriverHelper.override_config(drv, base_config, dbname: 'failedDatabaseNameTest')
      expect do
        Integration::DriverHelper.native_connect(drv, **bad_config)
      end.to raise_error(StandardError)
    end
  end

  context 'global database connectivity',
          features: [Integration::TestEnvironmentFeatures::GLOBAL_DATABASE] do
    before do
      skip 'Global Database not configured' unless env.global_cluster_endpoint
    end

    it 'connects to global cluster endpoint' do
      config = Integration::DriverHelper.native_config(
        drv,
        host: env.global_cluster_endpoint,
        port: writer.port,
        user: info.username,
        password: info.password,
        dbname: info.default_dbname
      )

      conn = Integration::DriverHelper.wrapper_connect(drv, **config, **wrapper_props)
      expect(query_one(conn)).to eq(1)
    ensure
      Integration::DriverHelper.close(drv, conn) if conn
    end

    it 'connects to primary cluster endpoint' do
      config = Integration::DriverHelper.native_config(
        drv,
        host: info.cluster_endpoint,
        port: writer.port,
        user: info.username,
        password: info.password,
        dbname: info.default_dbname
      )

      conn = Integration::DriverHelper.wrapper_connect(drv, **config, **wrapper_props)
      expect(query_one(conn)).to eq(1)
    ensure
      Integration::DriverHelper.close(drv, conn) if conn
    end

    it 'connects to secondary cluster endpoint' do
      skip 'Secondary cluster endpoint not available' unless env.secondary_cluster_endpoint

      config = Integration::DriverHelper.native_config(
        drv,
        host: env.secondary_cluster_endpoint,
        port: writer.port,
        user: info.username,
        password: info.password,
        dbname: info.default_dbname
      )

      conn = Integration::DriverHelper.wrapper_connect(drv, **config, **wrapper_props)
      expect(query_one(conn)).to eq(1)
    ensure
      Integration::DriverHelper.close(drv, conn) if conn
    end
  end
end
