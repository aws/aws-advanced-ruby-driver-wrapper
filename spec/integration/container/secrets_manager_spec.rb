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

require 'securerandom'
require 'aws-sdk-secretsmanager'
require_relative 'integration_helper'
require_relative 'utils/test_environment'
require_relative 'utils/test_environment_features'
require_relative 'utils/test_driver'
require_relative 'utils/driver_helper'
require_relative 'utils/connection_utils'
require 'aws_ruby_database_driver_wrapper'

RSpec.describe 'AwsSecretsManagerAuthentication', :integration,
               features: [Integration::TestEnvironmentFeatures::SECRETS_MANAGER],
               disable_on_features: [Integration::TestEnvironmentFeatures::PERFORMANCE] do
  let(:region) { env.aurora_region }

  before(:all) do
    @env = Integration::TestEnvironment.current
    @region = @env.aurora_region
    @sm_client = Aws::SecretsManager::Client.new(region: @region)

    @secret_id = "aws-ruby-wrapper-it-sm-#{SecureRandom.uuid}"
    secret_string = JSON.generate(
      username: @env.database_info.username,
      password: @env.database_info.password
    )
    response = @sm_client.create_secret(name: @secret_id, secret_string: secret_string)
    @secret_arn = response.arn
  end

  after(:all) do
    @sm_client&.delete_secret(secret_id: @secret_id, force_delete_without_recovery: true)
  rescue StandardError => e
    warn "Failed to delete test secret #{@secret_id}: #{e.message}"
  ensure
    @sm_client = nil
  end

  before do
    skip 'No allowed drivers for this environment' if drv.nil?
    begin
      AwsRubyDatabaseDriverWrapper.clear_caches
    rescue StandardError
      nil
    end
  end

  it 'connects with fetched credentials' do
    conn = create_sm_wrapper_connection(secret_id: @secret_id)
    result = Integration::DriverHelper.execute(drv, conn, 'SELECT 1 AS val')
    expect(result.first['val'].to_i).to eq(1)
  ensure
    Integration::DriverHelper.close(drv, conn) if conn
  end

  it 'second connection reuses cached credentials' do
    conn1 = create_sm_wrapper_connection(secret_id: @secret_id)
    Integration::DriverHelper.execute(drv, conn1, 'SELECT 1')

    # Verify the cache is populated after first connection
    sc = conn1.instance_variable_get(:@service_container)
    storage = sc.storage_service
    cache_key = "#{@secret_id}:#{region}"
    cached_entry = storage.get(:secrets_manager, cache_key)
    expect(cached_entry).not_to be_nil
    expect(cached_entry.expired?).to be false

    # Second connection should reuse the cached entry (no pending refresh triggered)
    conn2 = create_sm_wrapper_connection(secret_id: @secret_id)
    result = Integration::DriverHelper.execute(drv, conn2, 'SELECT 1 AS val')
    expect(result.first['val'].to_i).to eq(1)

    # Cache entry should be the same object (not re-fetched)
    cached_entry_after = storage.get(:secrets_manager, cache_key)
    expect(cached_entry_after.expires_at).to eq(cached_entry.expires_at)
    expect(AwsRubyDatabaseDriverWrapper::Plugins::SecretsManagerPlugin.pending_refreshes).to be_empty
  ensure
    Integration::DriverHelper.close(drv, conn1) if conn1
    Integration::DriverHelper.close(drv, conn2) if conn2
  end

  it 'connects using secret ARN (region parsed from ARN)' do
    conn = create_sm_wrapper_connection(secret_id: @secret_arn, region: nil)
    result = Integration::DriverHelper.execute(drv, conn, 'SELECT 1 AS val')
    expect(result.first['val'].to_i).to eq(1)
  ensure
    Integration::DriverHelper.close(drv, conn) if conn
  end

  it 'overrides explicit password with secret credentials' do
    conn = create_sm_wrapper_connection(secret_id: @secret_arn, region: nil, password: 'decoy_password')
    result = Integration::DriverHelper.execute(drv, conn, 'SELECT 1 AS val')
    expect(result.first['val'].to_i).to eq(1)
  ensure
    Integration::DriverHelper.close(drv, conn) if conn
  end

  it 'raises error for non-existent secret' do
    fake_secret_id = "aws-ruby-wrapper-it-sm-missing-#{SecureRandom.uuid}"
    expect do
      create_sm_wrapper_connection(secret_id: fake_secret_id)
    end.to raise_error(StandardError)
  end

  it 'serves stale credentials and immediately refreshes in background (SWR)' do
    conn1 = create_sm_wrapper_connection(secret_id: @secret_id)
    Integration::DriverHelper.execute(drv, conn1, 'SELECT 1')

    # Expire the cache entry to simulate staleness
    sc = conn1.instance_variable_get(:@service_container)
    storage = sc.storage_service
    cache_key = "#{@secret_id}:#{region}"
    current_entry = storage.get(:secrets_manager, cache_key)

    expired_entry = AwsRubyDatabaseDriverWrapper::Plugins::SecretsManagerPlugin::SecretEntry.new(
      username: current_entry.username,
      password: current_entry.password,
      expires_at: Process.clock_gettime(Process::CLOCK_MONOTONIC) - 10
    )
    storage.set(:secrets_manager, cache_key, expired_entry)

    # Second connection should be served stale credentials quickly (no blocking API call)
    start_time = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    conn2 = create_sm_wrapper_connection(secret_id: @secret_id)
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - start_time
    result = Integration::DriverHelper.execute(drv, conn2, 'SELECT 1 AS val')

    expect(result.first['val'].to_i).to eq(1)
    expect(elapsed).to be < 5.0

    # Wait for background refresh
    sleep(1)
    refreshed = storage.get(:secrets_manager, cache_key)
    expect(refreshed).not_to be_nil
    expect(refreshed.expired?).to be false
  ensure
    Integration::DriverHelper.close(drv, conn1) if conn1
    Integration::DriverHelper.close(drv, conn2) if conn2
  end

  it 'concurrent connections share single in-flight fetch (dedup)' do
    barrier = Concurrent::CountDownLatch.new(1)
    threads = Array.new(5) do
      Thread.new do
        barrier.wait # ensure all threads start simultaneously
        c = create_sm_wrapper_connection(secret_id: @secret_id)
        r = Integration::DriverHelper.execute(drv, c, 'SELECT 1 AS val')
        [c, r.first['val'].to_i]
      end
    end

    # Release all threads at once
    barrier.count_down

    results = threads.map(&:value)
    conns = results.map(&:first)
    values = results.map(&:last)

    expect(values).to all(eq(1))

    # All connections should share the same cached entry (same expires_at proves single fetch)
    entries = conns.map do |c|
      sc = c.instance_variable_get(:@service_container)
      sc.storage_service.get(:secrets_manager, "#{@secret_id}:#{region}")
    end
    expires_at_values = entries.compact.map(&:expires_at).uniq
    expect(expires_at_values.size).to eq(1)

    # Verify pending_refreshes is clean (all futures resolved)
    pending = AwsRubyDatabaseDriverWrapper::Plugins::SecretsManagerPlugin.pending_refreshes
    expect(pending).to be_empty
  ensure
    conns&.each { |c| Integration::DriverHelper.close(drv, c) if c }
  end

  it 'clear cache forces fresh fetch on next connection' do
    conn1 = create_sm_wrapper_connection(secret_id: @secret_id)
    Integration::DriverHelper.execute(drv, conn1, 'SELECT 1')

    sc = conn1.instance_variable_get(:@service_container)
    AwsRubyDatabaseDriverWrapper::Plugins::SecretsManagerPlugin.clear_cache(sc.storage_service)

    # Next connection must fetch from Secrets Manager again
    conn2 = create_sm_wrapper_connection(secret_id: @secret_id)
    result = Integration::DriverHelper.execute(drv, conn2, 'SELECT 1 AS val')
    expect(result.first['val'].to_i).to eq(1)
  ensure
    Integration::DriverHelper.close(drv, conn1) if conn1
    Integration::DriverHelper.close(drv, conn2) if conn2
  end

  it 'retries with fresh secret when cached secret causes login failure' do
    conn1 = create_sm_wrapper_connection(secret_id: @secret_id)
    Integration::DriverHelper.execute(drv, conn1, 'SELECT 1')

    # Corrupt cached credentials to simulate a rotated-but-stale secret
    sc = conn1.instance_variable_get(:@service_container)
    storage = sc.storage_service
    cache_key = "#{@secret_id}:#{region}"

    bad_entry = AwsRubyDatabaseDriverWrapper::Plugins::SecretsManagerPlugin::SecretEntry.new(
      username: 'invalid_user_does_not_exist',
      password: 'invalid_password',
      expires_at: Process.clock_gettime(Process::CLOCK_MONOTONIC) + 9999
    )
    storage.set(:secrets_manager, cache_key, bad_entry)

    # Next connection: stale secret → login error → force refetch from SM → succeed
    conn2 = create_sm_wrapper_connection(secret_id: @secret_id)
    result = Integration::DriverHelper.execute(drv, conn2, 'SELECT 1 AS val')
    expect(result.first['val'].to_i).to eq(1)
  ensure
    Integration::DriverHelper.close(drv, conn1) if conn1
    Integration::DriverHelper.close(drv, conn2) if conn2
  end

  it 'connects using explicit aws_credentials_provider' do
    explicit_creds = Aws::CredentialProviderChain.new.resolve

    conn = create_sm_wrapper_connection(
      secret_id: @secret_id,
      extra_props: {
        AwsRubyDatabaseDriverWrapper::PropertyDefinition::AWS_CREDENTIALS_PROVIDER.name => explicit_creds
      }
    )
    result = Integration::DriverHelper.execute(drv, conn, 'SELECT 1 AS val')
    expect(result.first['val'].to_i).to eq(1)
  ensure
    Integration::DriverHelper.close(drv, conn) if conn
  end

  private

  def create_sm_wrapper_connection(secret_id:, region: env.aurora_region, password: nil, extra_props: {})
    config = Integration::DriverHelper.native_config(
      drv,
      host: writer.host,
      port: writer.port,
      user: 'ignored',
      password: password || 'ignored',
      dbname: info.default_dbname
    )

    sm_props = {
      AwsRubyDatabaseDriverWrapper::PropertyDefinition::PLUGINS.name => 'secrets_manager',
      AwsRubyDatabaseDriverWrapper::PropertyDefinition::SECRET_ID.name => secret_id,
      AwsRubyDatabaseDriverWrapper::PropertyDefinition::CLUSTER_ID.name => env.cluster_name
    }
    sm_props[AwsRubyDatabaseDriverWrapper::PropertyDefinition::SECRET_REGION.name] = region if region

    Integration::DriverHelper.wrapper_connect(drv, **config, **sm_props, **extra_props)
  end
end
