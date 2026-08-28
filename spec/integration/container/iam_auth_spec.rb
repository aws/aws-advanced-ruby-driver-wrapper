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

require 'resolv'
require_relative 'integration_helper'
require_relative 'utils/test_environment'
require_relative 'utils/test_environment_features'
require_relative 'utils/test_driver'
require_relative 'utils/driver_helper'
require_relative 'utils/connection_utils'
require 'aws_advanced_ruby_driver_wrapper'

RSpec.describe 'AwsIamAuthentication', :integration,
               features: [Integration::TestEnvironmentFeatures::IAM],
               disable_on_features: [Integration::TestEnvironmentFeatures::PERFORMANCE] do
  let(:iam_props) { base_iam_props }

  let(:iam_config) do
    config = Integration::DriverHelper.native_config(
      drv,
      host: writer.host,
      port: writer.port,
      user: env.iam_user_name,
      password: 'anything',
      dbname: info.default_dbname
    )
    case drv
    when Integration::TestDriver::PG
      config.merge(sslmode: 'require')
    when Integration::TestDriver::MYSQL
      config.merge(ssl_mode: :required)
    else
      config
    end
  end

  before do
    skip 'No allowed drivers for this environment' if drv.nil?
    begin
      AwsAdvancedRubyDriverWrapper::Plugins::IamAuthPlugin.clear_cache(
        AwsAdvancedRubyDriverWrapper::Services::CoreServices.storage_service
      )
    rescue StandardError
      nil
    end
  end

  it 'connects with valid IAM credentials' do
    target_host = writer.host
    writer.port
    begin
      Resolv.getaddress(target_host)
    rescue StandardError => e
      "resolution_failed: #{e.message}"
    end

    conn = Integration::DriverHelper.wrapper_connect(drv, **iam_config, **iam_props)
    result = Integration::DriverHelper.execute(drv, conn, 'SELECT 1 AS val')
    expect(result.first['val'].to_i).to eq(1)
  ensure
    Integration::DriverHelper.close(drv, conn) if conn
  end

  it 'raises with wrong database username' do
    bad_config = Integration::DriverHelper.override_config(drv, iam_config, user: "WRONG_#{env.iam_user_name}_USER")

    expect do
      Integration::DriverHelper.wrapper_connect(drv, **bad_config, **iam_props)
    end.to raise_error(StandardError)
  end

  it 'raises with no database username' do
    no_user_config = Integration::DriverHelper.override_config(drv, iam_config, user: '')

    expect do
      Integration::DriverHelper.wrapper_connect(drv, **no_user_config, **iam_props)
    end.to raise_error(AwsAdvancedRubyDriverWrapper::Errors::IamAuthError)
  end

  it 'connects using IP address with iam_host override' do
    instance_host = writer.host
    host_ip = Resolv.getaddress(instance_host)

    ip_config = Integration::DriverHelper.native_config(
      drv,
      host: host_ip,
      port: writer.port,
      user: env.iam_user_name,
      password: 'anything',
      dbname: info.default_dbname
    )
    case drv
    when Integration::TestDriver::PG
      ip_config = ip_config.merge(sslmode: 'require')
    when Integration::TestDriver::MYSQL
      ip_config = ip_config.merge(ssl_mode: :required, enable_cleartext_plugin: true)
    end

    props_with_iam_host = iam_props.merge(
      AwsAdvancedRubyDriverWrapper::PropertyDefinition::IAM_HOST.name => instance_host
    )

    conn = Integration::DriverHelper.wrapper_connect(drv, **ip_config, **props_with_iam_host)
    result = Integration::DriverHelper.execute(drv, conn, 'SELECT 1 AS val')
    expect(result.first['val'].to_i).to eq(1)
  ensure
    Integration::DriverHelper.close(drv, conn) if conn
  end

  it 'retries with fresh token when cached token is expired' do
    # First connection — populates the cache
    conn1 = Integration::DriverHelper.wrapper_connect(drv, **iam_config, **iam_props)
    result = Integration::DriverHelper.execute(drv, conn1, 'SELECT 1 AS val')
    expect(result.first['val'].to_i).to eq(1)

    # Corrupt the cached token to simulate expiry
    sc = conn1.instance_variable_get(:@service_container)
    storage = sc.storage_service
    cache_name = AwsAdvancedRubyDriverWrapper::Plugins::IamAuthPlugin::IAM_TOKEN_CACHE_NAME
    iam_utils = AwsAdvancedRubyDriverWrapper::Utils::IamAuthUtils
    rds_utils = AwsAdvancedRubyDriverWrapper::Utils::RdsUtils

    region = rds_utils.rds_region(writer.host)
    cache_key = iam_utils.cache_key(region, writer.host, writer.port, env.iam_user_name)

    # Replace with an entry containing an invalid token (will cause login error → retry)
    bad_entry = iam_utils::TokenEntry.new(
      token: 'invalid-expired-token',
      expires_at: Process.clock_gettime(Process::CLOCK_MONOTONIC) + 9999
    )
    storage.set(cache_name, cache_key, bad_entry)

    # Second connection — should fail with cached bad token, then regenerate and succeed
    conn2 = Integration::DriverHelper.wrapper_connect(drv, **iam_config, **iam_props)
    result = Integration::DriverHelper.execute(drv, conn2, 'SELECT 1 AS val')
    expect(result.first['val'].to_i).to eq(1)
  ensure
    Integration::DriverHelper.close(drv, conn1) if conn1
    Integration::DriverHelper.close(drv, conn2) if conn2
  end

  it 'connects using explicit aws_credentials_provider' do
    explicit_creds = Aws::CredentialProviderChain.new.resolve

    conn = Integration::DriverHelper.wrapper_connect(
      drv,
      **iam_config,
      **iam_props.merge(
        AwsAdvancedRubyDriverWrapper::PropertyDefinition::AWS_CREDENTIALS_PROVIDER.name => explicit_creds
      )
    )
    result = Integration::DriverHelper.execute(drv, conn, 'SELECT 1 AS val')
    expect(result.first['val'].to_i).to eq(1)
  ensure
    Integration::DriverHelper.close(drv, conn) if conn
  end

  it 'concurrent connections share cached token' do
    # Open multiple connections in parallel — all should succeed
    threads = Array.new(5) do
      Thread.new do
        c = Integration::DriverHelper.wrapper_connect(drv, **iam_config, **iam_props)
        r = Integration::DriverHelper.execute(drv, c, 'SELECT 1 AS val')
        [c, r.first['val'].to_i]
      end
    end

    results = threads.map(&:value)
    conns = results.map(&:first)
    values = results.map(&:last)

    expect(values).to all(eq(1))

    # Verify that all connections shared a single cached token
    sc = conns.first.instance_variable_get(:@service_container)
    cache_size = sc.storage_service.size(
      AwsAdvancedRubyDriverWrapper::Plugins::IamAuthPlugin::IAM_TOKEN_CACHE_NAME
    )
    expect(cache_size).to eq(1)
  ensure
    conns&.each { |c| Integration::DriverHelper.close(drv, c) if c }
  end

  context 'global database endpoint', features: [Integration::TestEnvironmentFeatures::GLOBAL_DATABASE] do
    before do
      skip 'Global Database not configured' unless env.global_cluster_endpoint
    end

    let(:gdb_config) do
      config = Integration::DriverHelper.native_config(
        drv,
        host: env.global_cluster_endpoint,
        port: writer.port,
        user: env.iam_user_name,
        password: 'anything',
        dbname: info.default_dbname
      )
      case drv
      when Integration::TestDriver::PG
        config.merge(sslmode: 'require')
      when Integration::TestDriver::MYSQL
        config.merge(ssl_mode: :required)
      else
        config
      end
    end

    it 'connects via global cluster endpoint with IAM' do
      conn = Integration::DriverHelper.wrapper_connect(drv, **gdb_config, **iam_props)
      result = Integration::DriverHelper.execute(drv, conn, 'SELECT 1 AS val')
      expect(result.first['val'].to_i).to eq(1)
    ensure
      Integration::DriverHelper.close(drv, conn) if conn
    end

    it 'raises IamAuthError when iam_region is missing for global endpoint' do
      props_no_region = {
        AwsAdvancedRubyDriverWrapper::PropertyDefinition::PLUGINS.name => 'iam',
        AwsAdvancedRubyDriverWrapper::PropertyDefinition::CLUSTER_ID.name => env.cluster_name,
        AwsAdvancedRubyDriverWrapper::PropertyDefinition::GLOBAL_CLUSTER_INSTANCE_HOST_PATTERNS.name =>
          "[#{env.primary_region}]?.#{info.instance_endpoint_suffix}:#{writer.port}"
      }

      expect do
        Integration::DriverHelper.wrapper_connect(drv, **gdb_config, **props_no_region)
      end.to raise_error(AwsAdvancedRubyDriverWrapper::Errors::IamAuthError, /unable to determine connection region/)
    end

    it 'connects to secondary cluster endpoint with IAM' do
      skip 'Secondary cluster endpoint not available' unless env.secondary_cluster_endpoint

      secondary_config = Integration::DriverHelper.native_config(
        drv,
        host: env.secondary_cluster_endpoint,
        port: writer.port,
        user: env.iam_user_name,
        password: 'anything',
        dbname: info.default_dbname
      )
      case drv
      when Integration::TestDriver::PG
        secondary_config = secondary_config.merge(sslmode: 'require')
      when Integration::TestDriver::MYSQL
        secondary_config = secondary_config.merge(ssl_mode: :required)
      end

      secondary_props = iam_props.merge(
        AwsAdvancedRubyDriverWrapper::PropertyDefinition::IAM_REGION.name => env.secondary_region
      )

      conn = Integration::DriverHelper.wrapper_connect(drv, **secondary_config, **secondary_props)
      result = Integration::DriverHelper.execute(drv, conn, 'SELECT 1 AS val')
      expect(result.first['val'].to_i).to eq(1)
    ensure
      Integration::DriverHelper.close(drv, conn) if conn
    end

    it 'concurrent connections to global endpoint all succeed' do
      threads = Array.new(3) do
        Thread.new do
          c = Integration::DriverHelper.wrapper_connect(drv, **gdb_config, **iam_props)
          r = Integration::DriverHelper.execute(drv, c, 'SELECT 1 AS val')
          [c, r.first['val'].to_i]
        end
      end

      results = threads.map(&:value)
      conns = results.map(&:first)
      values = results.map(&:last)

      expect(values).to all(eq(1))
    ensure
      conns&.each { |c| Integration::DriverHelper.close(drv, c) if c }
    end
  end
end
