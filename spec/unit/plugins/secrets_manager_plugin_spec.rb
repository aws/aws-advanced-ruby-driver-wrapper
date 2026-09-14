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
require 'aws-sdk-secretsmanager'
require 'aws_advanced_ruby_driver_wrapper/plugins/secrets_manager_plugin'
require 'aws_advanced_ruby_driver_wrapper/host/host_info'
require 'aws_advanced_ruby_driver_wrapper/errors'

RSpec.describe AwsAdvancedRubyDriverWrapper::Plugins::SecretsManagerPlugin do
  let(:secret_json) { '{"username":"dbuser","password":"dbpass"}' }
  let(:secret_response) { double('GetSecretValueResponse', secret_string: secret_json) }
  let(:mock_sm_client) { instance_double(Aws::SecretsManager::Client) }
  let(:mock_credentials) { instance_double(Aws::Credentials, access_key_id: 'AKID', secret_access_key: 'SECRET') }
  let(:mock_storage_service) { instance_double(AwsAdvancedRubyDriverWrapper::Utils::Storage::StorageService) }
  let(:mock_driver_dialect) { double('DriverDialect', user_property_key: :user) }
  let(:mock_dialect_service) { double('DialectService', login_error?: false, driver_dialect: mock_driver_dialect) }
  let(:mock_service_container) do
    double('ServiceContainer',
           storage_service: mock_storage_service,
           dialect_service: mock_dialect_service)
  end

  let(:base_props) do
    props = Concurrent::Map.new
    props[:secret_id] = 'my-secret'
    props[:secret_region] = 'us-west-2'
    props
  end

  let(:host_info) do
    AwsAdvancedRubyDriverWrapper::Host::HostInfo.new(host: 'db.example.com', port: '5432')
  end

  before do
    allow(Aws::CredentialProviderChain).to receive(:new).and_return(double(resolve: mock_credentials))
    allow(Aws::SecretsManager::Client).to receive(:new).and_return(mock_sm_client)
    allow(mock_sm_client).to receive(:get_secret_value).and_return(secret_response)
    allow(mock_storage_service).to receive(:register)
    allow(mock_storage_service).to receive(:get).and_return(nil)
    allow(mock_storage_service).to receive(:set)
    # Clear pending refreshes between tests
    described_class.pending_refreshes.each_pair { |k, _| described_class.pending_refreshes.delete(k) }
  end

  def build_plugin(props = base_props)
    described_class.new(mock_service_container, props)
  end

  describe '#initialize' do
    it 'registers the secrets cache partition with the disposal lifetime' do
      build_plugin
      expect(mock_storage_service).to have_received(:register).with(
        :secrets_manager, ttl: described_class::SECRET_CACHE_DISPOSAL_SEC
      )
    end

    it 'raises when secret_id is missing' do
      base_props.delete(:secret_id)
      expect { build_plugin }.to raise_error(
        AwsAdvancedRubyDriverWrapper::Errors::SecretsManagerAuthError, /secret_id is required/
      )
    end

    it 'raises when region cannot be determined' do
      base_props.delete(:secret_region)
      expect { build_plugin }.to raise_error(
        AwsAdvancedRubyDriverWrapper::Errors::SecretsManagerAuthError, /Unable to determine region/
      )
    end

    # Drives through #connect and asserts the resolved region via the cache key
    # ("<secret_id>:<region>"), which is the observable signal that ARN parsing worked.
    def expect_region_parsed_from_arn(arn, expected_region)
      props = Concurrent::Map.new
      props[:secret_id] = arn
      plugin = build_plugin(props)
      plugin.connect(host_info, Concurrent::Map.new, true, -> {})
      expect(mock_storage_service).to have_received(:get).with(
        described_class::SECRETS_MANAGER_CACHE_NAME, "#{arn}:#{expected_region}"
      )
    end

    it 'parses region from ARN when no explicit region' do
      expect_region_parsed_from_arn('arn:aws:secretsmanager:eu-west-1:123456789:secret:my-secret', 'eu-west-1')
    end

    it 'parses region from an aws-cn (China) ARN' do
      expect_region_parsed_from_arn('arn:aws-cn:secretsmanager:cn-north-1:123456789:secret:my-secret', 'cn-north-1')
    end

    it 'parses region from an aws-us-gov (GovCloud) ARN' do
      expect_region_parsed_from_arn('arn:aws-us-gov:secretsmanager:us-gov-west-1:123456789:secret:my-secret', 'us-gov-west-1')
    end

    it 'clamps expiration below minimum to 300' do
      base_props[:secret_expiration_sec] = 100
      allow(AwsAdvancedRubyDriverWrapper.logger).to receive(:warn)
      build_plugin
      expect(AwsAdvancedRubyDriverWrapper.logger).to have_received(:warn)
        .with(/expiration 100s below minimum #{described_class::MIN_EXPIRATION_SEC}s, clamping/o)
    end

    it 'clamps expiration above the maximum, reserving the SWR revalidation window' do
      base_props[:secret_expiration_sec] = described_class::SECRET_CACHE_DISPOSAL_SEC
      allow(AwsAdvancedRubyDriverWrapper.logger).to receive(:warn)
      build_plugin
      expect(AwsAdvancedRubyDriverWrapper.logger).to have_received(:warn)
        .with(/exceeds the #{described_class::MAX_EXPIRATION_SEC}s maximum/o)
    end
  end

  describe '#connect' do
    it 'fetches secret and injects username/password into props' do
      plugin = build_plugin
      props = Concurrent::Map.new
      result = nil

      plugin.connect(host_info, props, true, -> { result = [props[:user], props[:password]] })

      expect(result).to eq(%w[dbuser dbpass])
    end

    it 'uses cached entry when fresh' do
      cached = described_class::SecretEntry.new(
        username: 'cached_user', password: 'cached_pass',
        expires_at: Process.clock_gettime(Process::CLOCK_MONOTONIC) + 900
      )
      allow(mock_storage_service).to receive(:get).and_return(cached)

      plugin = build_plugin
      props = Concurrent::Map.new
      result = nil

      plugin.connect(host_info, props, true, -> { result = [props[:user], props[:password]] })

      expect(result).to eq(%w[cached_user cached_pass])
      expect(mock_sm_client).not_to have_received(:get_secret_value)
    end
  end

  describe 'login error retry' do
    it 'retries with fresh credentials on login error' do
      cached = described_class::SecretEntry.new(
        username: 'old_user', password: 'old_pass',
        expires_at: Process.clock_gettime(Process::CLOCK_MONOTONIC) + 900
      )
      allow(mock_storage_service).to receive(:get).and_return(cached)
      allow(mock_dialect_service).to receive(:login_error?).and_return(true)

      plugin = build_plugin
      props = Concurrent::Map.new
      call_count = 0

      callable = lambda do
        call_count += 1
        raise StandardError, 'Access denied' if call_count == 1
      end

      plugin.connect(host_info, props, true, callable)

      expect(call_count).to eq(2)
      expect(props[:user]).to eq('dbuser')
      expect(props[:password]).to eq('dbpass')
    end

    it 'raises when retry also fails' do
      cached = described_class::SecretEntry.new(
        username: 'old_user', password: 'old_pass',
        expires_at: Process.clock_gettime(Process::CLOCK_MONOTONIC) + 900
      )
      allow(mock_storage_service).to receive(:get).and_return(cached)
      allow(mock_dialect_service).to receive(:login_error?).and_return(true)

      plugin = build_plugin
      props = Concurrent::Map.new

      callable = -> { raise StandardError, 'Access denied' }

      expect do
        plugin.connect(host_info, props, true, callable)
      end.to raise_error(StandardError, 'Access denied')
    end

    it 'does not retry when secret was freshly fetched' do
      allow(mock_dialect_service).to receive(:login_error?).and_return(true)

      plugin = build_plugin
      props = Concurrent::Map.new

      expect do
        plugin.connect(host_info, props, true, -> { raise StandardError, 'Access denied' })
      end.to raise_error(StandardError, 'Access denied')

      # Only one fetch call since it was fresh, no retry
      expect(mock_sm_client).to have_received(:get_secret_value).once
    end
  end

  describe 'custom JSON keys' do
    it 'uses custom username and password keys' do
      base_props[:secret_username_key] = 'db_user'
      base_props[:secret_password_key] = 'db_pass'

      custom_json = '{"db_user":"custom_user","db_pass":"custom_pass"}'
      allow(mock_sm_client).to receive(:get_secret_value)
        .and_return(double('Response', secret_string: custom_json))

      plugin = build_plugin
      props = Concurrent::Map.new
      result = nil

      plugin.connect(host_info, props, true, -> { result = [props[:user], props[:password]] })

      expect(result).to eq(%w[custom_user custom_pass])
    end

    it 'raises when JSON is missing required keys' do
      allow(mock_sm_client).to receive(:get_secret_value)
        .and_return(double('Response', secret_string: '{"other":"value"}'))

      plugin = build_plugin
      props = Concurrent::Map.new

      expect do
        plugin.connect(host_info, props, true, -> {})
      end.to raise_error(AwsAdvancedRubyDriverWrapper::Errors::SecretsManagerAuthError, /missing required keys/)
    end
  end

  describe 'custom endpoint' do
    it 'passes endpoint to the client' do
      base_props[:secret_endpoint] = 'http://localhost:4566'
      plugin = build_plugin
      props = Concurrent::Map.new
      plugin.connect(host_info, props, true, -> {})
      expect(Aws::SecretsManager::Client).to have_received(:new).with(
        hash_including(endpoint: 'http://localhost:4566')
      )
    end
  end

  describe '.clear_cache' do
    it 'clears the secrets_manager cache partition' do
      allow(mock_storage_service).to receive(:clear)
      described_class.clear_cache(mock_storage_service)
      expect(mock_storage_service).to have_received(:clear).with(:secrets_manager)
    end
  end

  describe '#internal_connect' do
    it 'behaves the same as connect' do
      plugin = build_plugin
      props = Concurrent::Map.new
      result = nil

      plugin.internal_connect(host_info, props, nil, true, -> { result = [props[:user], props[:password]] })

      expect(result).to eq(%w[dbuser dbpass])
    end
  end

  describe 'thundering herd protection' do
    it 'deduplicates concurrent fetches for the same key' do
      call_count = Concurrent::AtomicFixnum.new(0)
      allow(mock_sm_client).to receive(:get_secret_value) do
        call_count.increment
        sleep(0.05)
        secret_response
      end

      plugin = build_plugin
      threads = Array.new(3) do
        Thread.new do
          p = Concurrent::Map.new
          plugin.connect(host_info, p, true, -> {})
        end
      end
      threads.each(&:join)

      # Should have only one actual API call due to dedup
      expect(call_count.value).to eq(1)
    end
  end

  describe 'rotation retry budget' do
    def now
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    let(:rotation_props) do
      props = Concurrent::Map.new
      props[:secret_id] = 'my-secret'
      props[:secret_region] = 'us-west-2'
      props[:secret_rotation_retry_timeout_ms] = 5000
      props[:secret_rotation_retry_base_delay_ms] = 50
      props
    end

    it 'uses the cached secret on the first attempt without fetching' do
      cached = described_class::SecretEntry.new(
        username: 'cached_user', password: 'cached_pass', expires_at: now + 900
      )
      allow(mock_storage_service).to receive(:get).and_return(cached)

      plugin = build_plugin(rotation_props)
      props = Concurrent::Map.new
      plugin.connect(host_info, props, true, -> {})

      expect(props[:user]).to eq('cached_user')
      expect(mock_sm_client).not_to have_received(:get_secret_value)
    end

    it 'does not enter the retry budget when the timeout is 0 (disabled)' do
      cached = described_class::SecretEntry.new(
        username: 'old_user', password: 'old_pass', expires_at: now + 900
      )
      allow(mock_storage_service).to receive(:get).and_return(cached)
      allow(mock_dialect_service).to receive(:login_error?).and_return(true)

      plugin = build_plugin # default: rotation_retry_timeout_ms = 0
      props = Concurrent::Map.new
      call_count = 0

      callable = lambda do
        call_count += 1
        raise StandardError, 'Access denied'
      end

      expect do
        plugin.connect(host_info, props, true, callable)
      end.to raise_error(StandardError, 'Access denied')

      # Only 2 attempts: cached attempt + one forced refetch retry, then it gives up.
      expect(call_count).to eq(2)
    end

    it 'keeps re-fetching a cold cache until credentials are promoted' do
      allow(mock_storage_service).to receive(:get).and_return(nil)
      allow(mock_dialect_service).to receive(:login_error?).and_return(true)

      call_count = 0
      callable = lambda do
        call_count += 1
        raise StandardError, 'Access denied' if call_count < 3
      end

      plugin = build_plugin(rotation_props)
      expect { plugin.connect(host_info, Concurrent::Map.new, true, callable) }.not_to raise_error
      expect(call_count).to eq(3)
      expect(mock_sm_client).to have_received(:get_secret_value).at_least(2).times
    end

    it 'reports the login error when the budget is exhausted, not a transient fetch error' do
      cached = described_class::SecretEntry.new(
        username: 'old_user', password: 'old_pass', expires_at: now + 900
      )
      allow(mock_storage_service).to receive(:get).and_return(cached)
      allow(mock_dialect_service).to receive(:login_error?).and_return(true)

      seq = 0
      allow(mock_sm_client).to receive(:get_secret_value) do
        seq += 1
        raise StandardError, 'Throttling: Rate exceeded' if seq == 2

        secret_response
      end

      short_budget = rotation_props.tap { |p| p[:secret_rotation_retry_timeout_ms] = 400 }
      plugin = build_plugin(short_budget)

      error = nil
      begin
        plugin.connect(host_info, Concurrent::Map.new, true, -> { raise StandardError, 'Access denied' })
      rescue StandardError => e
        error = e
      end

      expect(error.message).to eq('Access denied')
      expect(seq).to be >= 3
    end

    it 'raises a non-login error immediately without re-fetching' do
      allow(mock_storage_service).to receive(:get).and_return(nil)
      allow(mock_dialect_service).to receive(:login_error?).and_return(false)

      plugin = build_plugin(rotation_props)
      call_count = 0
      callable = lambda do
        call_count += 1
        raise StandardError, 'network error'
      end

      expect do
        plugin.connect(host_info, Concurrent::Map.new, true, callable)
      end.to raise_error(StandardError, 'network error')

      expect(call_count).to eq(1)
      expect(mock_sm_client).to have_received(:get_secret_value).once
    end

    it 'caps the backoff delay and stays within the configured timeout' do
      allow(mock_storage_service).to receive(:get).and_return(nil)
      allow(mock_dialect_service).to receive(:login_error?).and_return(true)

      budget_ms = 1000
      props = rotation_props.tap do |p|
        p[:secret_rotation_retry_timeout_ms] = budget_ms
        p[:secret_rotation_retry_base_delay_ms] = 100
      end
      plugin = build_plugin(props)

      slept = []
      original_sleep = Kernel.method(:sleep)
      allow(plugin).to receive(:sleep) do |sec|
        slept << sec
        original_sleep.call(sec)
      end

      start = now
      expect do
        plugin.connect(host_info, Concurrent::Map.new, true, -> { raise StandardError, 'Access denied' })
      end.to raise_error(StandardError, 'Access denied')
      elapsed = now - start

      expect(slept).not_to be_empty
      expect(slept.max).to be <= described_class::MAX_RETRY_DELAY_SEC
      expect(slept.first).to be <= slept.last
      expect(elapsed).to be < (budget_ms / 1000.0) + 0.5
    end

    it 'serves a stale entry and refreshes in the background through the real storage layer' do
      real_storage = AwsAdvancedRubyDriverWrapper::Utils::Storage::StorageService.new(event_publisher: nil)
      allow(mock_service_container).to receive(:storage_service).and_return(real_storage)

      plugin = build_plugin(base_props)

      stale = described_class::SecretEntry.new(
        username: 'stale_user', password: 'stale_pass', expires_at: now - 1
      )
      real_storage.set(described_class::SECRETS_MANAGER_CACHE_NAME, 'my-secret:us-west-2', stale)

      props = Concurrent::Map.new
      plugin.connect(host_info, props, true, -> {})

      expect(props[:user]).to eq('stale_user')
      sleep(0.1)
      expect(mock_sm_client).to have_received(:get_secret_value)
    ensure
      real_storage&.shutdown
    end
  end

  describe 'SecretEntry redaction' do
    let(:entry) do
      described_class::SecretEntry.new(username: 'dbuser', password: 'super-secret-pass', expires_at: 123.0)
    end

    it 'redacts the password in #inspect while keeping the username' do
      expect(entry.inspect).not_to include('super-secret-pass')
      expect(entry.inspect).to include(AwsAdvancedRubyDriverWrapper::REDACTED)
      expect(entry.inspect).to include('dbuser')
    end

    it 'redacts the password in #to_s' do
      expect(entry.to_s).not_to include('super-secret-pass')
      expect(entry.to_s).to include(AwsAdvancedRubyDriverWrapper::REDACTED)
    end

    it 'redacts the password when interpolated into a string' do
      expect("entry=#{entry}").not_to include('super-secret-pass')
    end

    it 'still exposes the password via the accessor for internal use' do
      expect(entry.password).to eq('super-secret-pass')
    end
  end
end
