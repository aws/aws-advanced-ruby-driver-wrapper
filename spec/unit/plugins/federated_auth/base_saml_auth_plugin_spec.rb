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

require_relative '../../../spec_helper'
require 'aws-sdk-rds'
require 'aws_advanced_ruby_driver_wrapper/plugins/federated_auth/base_saml_auth_plugin'
require 'aws_advanced_ruby_driver_wrapper/host/host_info'
require 'aws_advanced_ruby_driver_wrapper/utils/rds_url_type'
require 'aws_advanced_ruby_driver_wrapper/utils/rds_utils'
require 'aws_advanced_ruby_driver_wrapper/utils/iam_auth_utils'
require 'aws_advanced_ruby_driver_wrapper/utils/saml_utils'
require 'aws_advanced_ruby_driver_wrapper/errors'

# A minimal concrete SAML plugin. It only declares the IdP seam (and a required
# property) so the base flow can be driven and the seam stubbed; it performs no
# HTTP of its own.
class TestSamlPlugin < AwsAdvancedRubyDriverWrapper::Plugins::FederatedAuth::BaseSamlAuthPlugin
  def self.fetch_saml_assertion(**_opts)
    raise 'fetch_saml_assertion must be stubbed in specs'
  end
end

RSpec.describe AwsAdvancedRubyDriverWrapper::Plugins::FederatedAuth::BaseSamlAuthPlugin do
  subject(:described_class) { TestSamlPlugin }

  SAML_GENERATED_TOKEN = 'someTestToken'
  SAML_CACHED_TOKEN    = 'cachedToken'
  SAML_DEFAULT_PG_PORT = 5432

  SAML_PG_HOST       = 'pg.testdb.us-east-2.rds.amazonaws.com'
  SAML_IAM_HOST_OVER = 'pg-123.testdb.us-east-2.rds.amazonaws.com'
  SAML_GLOBAL_HOST   = 'gdb.global-abc123.global.rds.amazonaws.com'
  SAML_DB_USER       = 'iamUser'

  SAML_FAKE_SAML_ASSERTION = 'fake-base64-saml-assertion'

  SAML_PRINCIPAL_FINGERPRINT =
    AwsAdvancedRubyDriverWrapper::Utils::SamlUtils.principal_fingerprint(
      'arn:aws:iam::123456789012:role/example_iam_role',
      'arn:aws:iam::123456789012:saml-provider/example'
    )

  SAML_PG_CACHE_KEY = "us-east-2:#{SAML_PG_HOST}:#{SAML_DEFAULT_PG_PORT}:#{SAML_DB_USER}:#{SAML_PRINCIPAL_FINGERPRINT}".freeze

  SAML_TOKEN_CACHE_NAME =
    AwsAdvancedRubyDriverWrapper::Plugins::FederatedAuth::BaseSamlAuthPlugin::IAM_TOKEN_CACHE_NAME

  SAML_IAM_AUTH_UTILS = AwsAdvancedRubyDriverWrapper::Utils::IamAuthUtils

  def pg_host_info(port: nil)
    AwsAdvancedRubyDriverWrapper::Host::HostInfo.new(
      host: SAML_PG_HOST,
      port: port ? port.to_s : AwsAdvancedRubyDriverWrapper::Host::HostInfo::NO_PORT
    )
  end

  def arbitrary_host_info(host)
    AwsAdvancedRubyDriverWrapper::Host::HostInfo.new(host:)
  end

  # The SAML identity a real connection string supplies. idp_username /
  # idp_password are deliberately omitted so the fallback-to-user/password
  # behaviour can be exercised. Every key is a registered WrapperProperty, so
  # this is wrapper-props shaped (see `build_plugin`).
  def base_wrapper_props
    {
      db_user: SAML_DB_USER,
      idp_endpoint: 'ec2amaz-ab3cdef.example.com',
      iam_role_arn: 'arn:aws:iam::123456789012:role/example_iam_role',
      iam_idp_arn: 'arn:aws:iam::123456789012:saml-provider/example',
      iam_region: 'us-east-2'
    }
  end

  def valid_token_entry(token = SAML_CACHED_TOKEN)
    SAML_IAM_AUTH_UTILS::TokenEntry.new(
      token:,
      expires_at: Process.clock_gettime(Process::CLOCK_MONOTONIC) + 900
    )
  end

  let(:mock_storage_service) { instance_double(AwsAdvancedRubyDriverWrapper::Utils::Storage::StorageService) }
  let(:mock_db_dialect) { double('DbDialect') }
  let(:mock_driver_dialect) { double('DriverDialect', user_property_key: :user) }
  let(:mock_dialect_service) do
    double('DialectService',
           db_dialect: mock_db_dialect,
           login_error?: false,
           driver_dialect: mock_driver_dialect)
  end
  let(:mock_service_container) do
    double('ServiceContainer',
           storage_service: mock_storage_service,
           dialect_service: mock_dialect_service)
  end

  let(:mock_credentials) { Aws::Credentials.new('AKID', 'SECRET') }
  let(:mock_token_generator) { instance_double(Aws::RDS::AuthTokenGenerator) }

  before do
    # The IdP seam that returns a SAML assertion and the STS exchange that turns
    # it into AWS credentials are both replaced so no HTTP ever happens.
    allow(described_class).to receive(:fetch_saml_assertion).and_return(SAML_FAKE_SAML_ASSERTION)
    allow(described_class).to receive(:credentials_from_saml).and_return(mock_credentials)

    allow(Aws::RDS::AuthTokenGenerator).to receive(:new).and_return(mock_token_generator)
    allow(mock_token_generator).to receive(:auth_token).and_return(SAML_GENERATED_TOKEN)

    allow(mock_storage_service).to receive(:register)
    allow(mock_storage_service).to receive(:get).with(SAML_TOKEN_CACHE_NAME, anything).and_return(nil)
    allow(mock_storage_service).to receive(:set)
    allow(mock_db_dialect).to receive(:default_port).and_return(SAML_DEFAULT_PG_PORT)
  end

  def wrapper_props_map(hash)
    map = Concurrent::Map.new
    hash.each { |k, v| map[k] = v }
    map
  end

  def build_plugin(wrapper_overrides = {})
    described_class.new(mock_service_container, wrapper_props_map(base_wrapper_props.merge(wrapper_overrides)))
  end

  # Connects, always raising inside the pipeline callable, and returns the
  # user/password the plugin injected into driver_props.
  def connect_and_capture(plugin:, host_info:, driver_props: {})
    plugin.connect(host_info, driver_props, true, -> { raise StandardError, 'simulated driver error' })
  rescue StandardError
    [driver_props[:user], driver_props[:password]]
  end

  describe '#initialize' do
    it 'registers the shared IAM token cache with the configured expiration ttl' do
      build_plugin(iam_expiration_sec: '600')
      expect(mock_storage_service).to have_received(:register).with(SAML_TOKEN_CACHE_NAME, ttl: 600.0)
    end

    it 'raises when the configured expiration exceeds the cache validity bound' do
      expect { build_plugin(iam_expiration_sec: '-5') }.to raise_error(ArgumentError)
    end
  end

  describe '#connect with a valid cached token' do
    it 'injects db_user and the cached token without touching the IdP or minting a token' do
      allow(mock_storage_service).to receive(:get).with(SAML_TOKEN_CACHE_NAME, SAML_PG_CACHE_KEY)
                                                  .and_return(valid_token_entry)

      user, password = connect_and_capture(plugin: build_plugin, host_info: pg_host_info)

      expect(user).to eq(SAML_DB_USER)
      expect(password).to eq(SAML_CACHED_TOKEN)
      expect(described_class).not_to have_received(:fetch_saml_assertion)
      expect(mock_token_generator).not_to have_received(:auth_token)
    end
  end

  describe '#connect with no cached token' do
    it 'fetches a SAML assertion, mints a fresh token, and injects it' do
      user, password = connect_and_capture(plugin: build_plugin, host_info: pg_host_info)

      expect(described_class).to have_received(:fetch_saml_assertion).once
      expect(mock_token_generator).to have_received(:auth_token).once.with(
        region: 'us-east-2',
        endpoint: "#{SAML_PG_HOST}:#{SAML_DEFAULT_PG_PORT}",
        user_name: SAML_DB_USER
      )
      expect(user).to eq(SAML_DB_USER)
      expect(password).to eq(SAML_GENERATED_TOKEN)
    end

    it 'stores the freshly minted token under the cache key' do
      connect_and_capture(plugin: build_plugin, host_info: pg_host_info)

      expect(mock_storage_service).to have_received(:set).with(
        SAML_TOKEN_CACHE_NAME, SAML_PG_CACHE_KEY, having_attributes(token: SAML_GENERATED_TOKEN)
      )
    end

    it 'signs the token with the STS credentials exchanged from the SAML assertion' do
      captured_signing_credentials = nil
      allow(Aws::RDS::AuthTokenGenerator).to receive(:new) do |credentials:|
        captured_signing_credentials = credentials
        mock_token_generator
      end

      connect_and_capture(plugin: build_plugin, host_info: pg_host_info)

      expect(described_class).to have_received(:credentials_from_saml).with(
        SAML_FAKE_SAML_ASSERTION,
        role_arn: 'arn:aws:iam::123456789012:role/example_iam_role',
        idp_arn: 'arn:aws:iam::123456789012:saml-provider/example',
        region: 'us-east-2'
      )
      expect(captured_signing_credentials.access_key_id).to eq('AKID')
    end
  end

  describe '#connect with iam_host / iam_port / iam_region overrides' do
    it 'uses the overridden host, port, and region to mint the token' do
      plugin = build_plugin(iam_host: 'pg.testdb.us-west-2.rds.amazonaws.com',
                            iam_port: '9876', iam_region: 'us-west-2')

      connect_and_capture(plugin:, host_info: pg_host_info)

      expect(mock_token_generator).to have_received(:auth_token).with(
        region: 'us-west-2',
        endpoint: 'pg.testdb.us-west-2.rds.amazonaws.com:9876',
        user_name: SAML_DB_USER
      )
    end

    it 'mints the token against iam_host rather than the connection host' do
      connect_and_capture(
        plugin: build_plugin(iam_host: SAML_IAM_HOST_OVER),
        host_info: arbitrary_host_info('8.8.8.8')
      )

      expect(mock_token_generator).to have_received(:auth_token).with(
        hash_including(endpoint: "#{SAML_IAM_HOST_OVER}:#{SAML_DEFAULT_PG_PORT}", user_name: SAML_DB_USER)
      )
    end
  end

  describe '#connect IdP credential fallback' do
    before do
      allow(described_class).to receive(:fetch_saml_assertion) do |idp_username:, idp_password:, **_rest|
        @captured_idp = { username: idp_username, password: idp_password }
        SAML_FAKE_SAML_ASSERTION
      end
    end

    it 'uses idp_username / idp_password when provided' do
      plugin = build_plugin(idp_username: 'jimbob@example.com', idp_password: 'idpSecret')
      connect_and_capture(plugin:, host_info: pg_host_info,
                          driver_props: { user: 'ignoredUser', password: 'ignoredPassword' })

      expect(@captured_idp).to eq(username: 'jimbob@example.com', password: 'idpSecret')
    end

    it 'falls back to the connection user / password when idp_username / idp_password are absent' do
      connect_and_capture(plugin: build_plugin, host_info: pg_host_info,
                          driver_props: { user: 'fallbackUser', password: 'fallbackPassword' })

      expect(@captured_idp).to eq(username: 'fallbackUser', password: 'fallbackPassword')
    end

    # Regression: the connect flow overwrites driver_props[:user]/[:password] with db_user and the
    # RDS token, and that hash is reused across reconnects (failover, retry, Blue/Green rerouting).
    # The fallback IdP login must still be the ORIGINAL user/password on the second connect, not the
    # overwritten db_user and stale token.
    it 'keeps using the original user/password for the IdP login across a reconnect that reuses driver_props' do
      captured = []
      allow(described_class).to receive(:fetch_saml_assertion) do |idp_username:, idp_password:, **_rest|
        captured << [idp_username, idp_password]
        SAML_FAKE_SAML_ASSERTION
      end

      plugin = build_plugin
      driver_props = { user: 'realUser', password: 'realPw' }
      2.times do
        plugin.connect(pg_host_info, driver_props, true, -> { raise StandardError, 'simulated' })
      rescue StandardError
        nil
      end

      expect(captured).to eq([%w[realUser realPw], %w[realUser realPw]])
      expect(driver_props[:user]).to eq(SAML_DB_USER)
      expect(driver_props[:password]).to eq(SAML_GENERATED_TOKEN)
    end
  end

  describe '#connect retry on login error with a cached token' do
    it 'mints a fresh SAML-derived token and retries the pipeline once' do
      allow(mock_storage_service).to receive(:get).with(SAML_TOKEN_CACHE_NAME, SAML_PG_CACHE_KEY)
                                                  .and_return(valid_token_entry)
      allow(mock_dialect_service).to receive(:login_error?).and_return(true)

      calls = 0
      retrying = lambda do
        calls += 1
        raise StandardError, 'login failure' if calls == 1

        :ok
      end

      result = build_plugin.connect(pg_host_info, {}, true, retrying)

      expect(result).to eq(:ok)
      expect(calls).to eq(2)
      expect(mock_token_generator).to have_received(:auth_token).once
    end

    it 'injects the freshly minted token, not the stale cached one, on the retry' do
      allow(mock_storage_service).to receive(:get).with(SAML_TOKEN_CACHE_NAME, SAML_PG_CACHE_KEY)
                                                  .and_return(valid_token_entry)
      allow(mock_dialect_service).to receive(:login_error?).and_return(true)
      allow(mock_token_generator).to receive(:auth_token).and_return('fresh-token')

      driver_props = {}
      passwords = []
      calls = 0
      retrying = lambda do
        calls += 1
        passwords << driver_props[:password]
        raise StandardError, 'login failure' if calls == 1

        :ok
      end

      build_plugin.connect(pg_host_info, driver_props, true, retrying)

      # First attempt uses the cached token; the retry uses the freshly minted one.
      expect(passwords).to eq([SAML_CACHED_TOKEN, 'fresh-token'])
    end

    it 'does not retry when the token was freshly minted (not from cache)' do
      allow(mock_dialect_service).to receive(:login_error?).and_return(true)

      calls = 0
      always_failing = lambda do
        calls += 1
        raise StandardError, 'login failure'
      end

      expect do
        build_plugin.connect(pg_host_info, {}, true, always_failing)
      end.to raise_error(StandardError, 'login failure')

      expect(calls).to eq(1)
    end

    it 're-raises a non-login error without retrying even with a cached token' do
      allow(mock_storage_service).to receive(:get).with(SAML_TOKEN_CACHE_NAME, SAML_PG_CACHE_KEY)
                                                  .and_return(valid_token_entry)
      allow(mock_dialect_service).to receive(:login_error?).and_return(false)

      calls = 0
      failing = lambda do
        calls += 1
        raise StandardError, 'not a login error'
      end

      expect do
        build_plugin.connect(pg_host_info, {}, true, failing)
      end.to raise_error(StandardError, 'not a login error')
      expect(calls).to eq(1)
    end
  end

  describe '#connect validation' do
    {
      'db_user' => :db_user,
      'idp_endpoint' => :idp_endpoint,
      'iam_role_arn' => :iam_role_arn,
      'iam_idp_arn' => :iam_idp_arn
    }.each do |name, key|
      it "raises SamlAuthError when #{name} is missing" do
        expect do
          build_plugin(key => nil).connect(pg_host_info, {}, true, -> {})
        end.to raise_error(AwsAdvancedRubyDriverWrapper::Errors::SamlAuthError, /#{name}/)
      end
    end

    it 'lists every missing property in one error' do
      expect do
        build_plugin(db_user: nil, iam_role_arn: nil).connect(pg_host_info, {}, true, -> {})
      end.to raise_error(AwsAdvancedRubyDriverWrapper::Errors::SamlAuthError, /db_user.*iam_role_arn|iam_role_arn.*db_user/)
    end
  end

  describe '#connect region resolution' do
    it 'raises SamlAuthError when the region cannot be determined' do
      plugin = build_plugin(iam_region: nil)
      expect do
        plugin.connect(arbitrary_host_info('not-an-rds-host.example.com'), {}, true, -> {})
      end.to raise_error(AwsAdvancedRubyDriverWrapper::Errors::SamlAuthError, /region/)
    end
  end

  describe '#connect against a global writer cluster' do
    it 'with an explicit iam_region, defers the SAML exchange to the token-cache miss path' do
      # iam_region makes the region resolvable without credentials, so there is no up-front
      # SAML exchange - the IdP round-trip happens only when minting on a cache miss.
      connect_and_capture(
        plugin: build_plugin(iam_region: 'us-east-2'),
        host_info: arbitrary_host_info(SAML_GLOBAL_HOST)
      )

      expect(described_class).to have_received(:fetch_saml_assertion).once
      expect(described_class).to have_received(:credentials_from_saml).once
      expect(mock_token_generator).to have_received(:auth_token).once
    end

    it 'with an explicit iam_region and a cached token, does not call the IdP at all' do
      # A global endpoint with iam_region no longer logs in to the IdP before the
      # cache check, so a pool/failover storm of cache hits triggers zero IdP logins.
      allow(mock_storage_service).to receive(:get).with(SAML_TOKEN_CACHE_NAME, SAML_PG_CACHE_KEY)
                                                  .and_return(valid_token_entry)
      allow(mock_storage_service).to receive(:get)
        .with(SAML_TOKEN_CACHE_NAME, "us-east-2:#{SAML_GLOBAL_HOST}:#{SAML_DEFAULT_PG_PORT}:#{SAML_DB_USER}:#{SAML_PRINCIPAL_FINGERPRINT}")
        .and_return(valid_token_entry)

      connect_and_capture(
        plugin: build_plugin(iam_region: 'us-east-2'),
        host_info: arbitrary_host_info(SAML_GLOBAL_HOST)
      )

      expect(described_class).not_to have_received(:fetch_saml_assertion)
      expect(mock_token_generator).not_to have_received(:auth_token)
    end

    it 'with no iam_region, assumes credentials up front and resolves the region with them' do
      allow(SAML_IAM_AUTH_UTILS).to receive(:region_for).and_return('us-east-2')

      connect_and_capture(
        plugin: build_plugin(iam_region: nil),
        host_info: arbitrary_host_info(SAML_GLOBAL_HOST)
      )

      expect(described_class).to have_received(:fetch_saml_assertion).at_least(:once)
      expect(SAML_IAM_AUTH_UTILS).to have_received(:region_for)
        .with(hash_including(credentials_provider: mock_credentials))
    end
  end

  describe 'cache key' do
    it 'is region:host:port:db_user:principal-fingerprint' do
      captured_key = nil
      allow(mock_storage_service).to receive(:set) { |_name, key, _value| captured_key = key }

      connect_and_capture(plugin: build_plugin, host_info: pg_host_info)

      expect(captured_key).to eq(SAML_PG_CACHE_KEY)
    end

    it 'never contains the raw STS access key id' do
      allow(described_class).to receive(:credentials_from_saml)
        .and_return(Aws::Credentials.new('AKIDVISIBLE', 'SECRET'))
      captured_key = nil
      allow(mock_storage_service).to receive(:set) { |_name, key, _value| captured_key = key }

      connect_and_capture(plugin: build_plugin, host_info: pg_host_info)

      expect(captured_key).not_to include('AKIDVISIBLE')
    end
  end

  describe '#internal_connect' do
    it 'defaults to @wrapper_props when the override is nil' do
      allow(mock_storage_service).to receive(:get).with(SAML_TOKEN_CACHE_NAME, SAML_PG_CACHE_KEY)
                                                  .and_return(valid_token_entry)

      driver_props = {}
      begin
        build_plugin.internal_connect(pg_host_info, driver_props, nil, true, -> { raise StandardError, 'simulated' })
      rescue StandardError
        nil
      end

      expect(driver_props[:user]).to eq(SAML_DB_USER)
      expect(driver_props[:password]).to eq(SAML_CACHED_TOKEN)
    end

    it 'honours an iam_host supplied via the wrapper_props override' do
      override_host = 'override.testdb.us-east-2.rds.amazonaws.com'
      begin
        build_plugin.internal_connect(pg_host_info, {},
                                      wrapper_props_map(base_wrapper_props.merge(iam_host: override_host)),
                                      false, -> { raise StandardError, 'simulated' })
      rescue StandardError
        nil
      end

      expect(mock_token_generator).to have_received(:auth_token).with(
        hash_including(endpoint: "#{override_host}:#{SAML_DEFAULT_PG_PORT}")
      )
    end
  end

  describe '#subscribed_methods' do
    it 'subscribes to connect and internal_connect only' do
      expect(build_plugin.subscribed_methods).to include('connect', 'internal_connect')
      expect(build_plugin.subscribed_methods).not_to include('execute')
    end
  end

  describe '.clear_cache' do
    it 'delegates to the storage service with the shared IAM token cache name' do
      allow(mock_storage_service).to receive(:clear)
      described_class.clear_cache(mock_storage_service)
      expect(mock_storage_service).to have_received(:clear).with(SAML_TOKEN_CACHE_NAME)
    end
  end

  describe '.credentials_from_saml' do
    it 'exchanges the assertion via STS AssumeRoleWithSAML and returns the credentials' do
      allow(described_class).to receive(:credentials_from_saml).and_call_original
      sts_client = instance_double(Aws::STS::Client)
      sts_creds = double('StsCreds', access_key_id: 'AKIASTS', secret_access_key: 'secret', session_token: 'session')
      allow(Aws::STS::Client).to receive(:new).and_return(sts_client)
      allow(sts_client).to receive(:assume_role_with_saml)
        .and_return(double('Resp', credentials: sts_creds))

      creds = described_class.credentials_from_saml(
        SAML_FAKE_SAML_ASSERTION,
        role_arn: 'role', idp_arn: 'idp', region: 'us-east-2'
      )

      expect(Aws::STS::Client).to have_received(:new).with(region: 'us-east-2', credentials: nil)
      expect(sts_client).to have_received(:assume_role_with_saml).with(
        role_arn: 'role', principal_arn: 'idp', saml_assertion: SAML_FAKE_SAML_ASSERTION
      )
      expect(creds.access_key_id).to eq('AKIASTS')
      expect(creds.session_token).to eq('session')
    end
  end
end
