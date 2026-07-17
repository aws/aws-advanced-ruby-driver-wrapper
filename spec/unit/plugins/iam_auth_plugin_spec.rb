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
require 'aws_ruby_database_driver_wrapper/plugins/iam_auth_plugin'
require 'aws_ruby_database_driver_wrapper/host/host_info'
require 'aws_ruby_database_driver_wrapper/utils/rds_url_type'
require 'aws_ruby_database_driver_wrapper/utils/rds_utils'
require 'aws_ruby_database_driver_wrapper/utils/iam_auth_utils'
require 'aws_ruby_database_driver_wrapper/errors'

RSpec.describe AwsRubyDatabaseDriverWrapper::Plugins::IamAuthPlugin do
  GENERATED_TOKEN    = 'generatedToken'
  TEST_TOKEN         = 'testToken'
  DEFAULT_PG_PORT    = 5432
  DEFAULT_MYSQL_PORT = 3306

  PG_HOST    = 'pg.testdb.us-east-2.rds.amazonaws.com'
  MYSQL_HOST = 'mysql.testdb.us-east-2.rds.amazonaws.com'
  GDB_HOST   = 'mydb.global-xyz123.global.rds.amazonaws.com'

  PG_CACHE_KEY    = "us-east-2:#{PG_HOST}:#{DEFAULT_PG_PORT}:postgresqlUser".freeze
  MYSQL_CACHE_KEY = "us-east-2:#{MYSQL_HOST}:#{DEFAULT_MYSQL_PORT}:mysqlUser".freeze
  GDB_CACHE_KEY   = "us-east-1:#{GDB_HOST}:#{DEFAULT_PG_PORT}:postgresqlUser".freeze

  IAM_TOKEN_CACHE_NAME = AwsRubyDatabaseDriverWrapper::Plugins::IamAuthPlugin::IAM_TOKEN_CACHE_NAME

  IAM_AUTH_UTILS = AwsRubyDatabaseDriverWrapper::Utils::IamAuthUtils
  RDS_URL_TYPE   = AwsRubyDatabaseDriverWrapper::Utils::RdsUrlType

  def pg_host_info(port: nil)
    AwsRubyDatabaseDriverWrapper::Host::HostInfo.new(
      host: PG_HOST,
      port: port ? port.to_s : AwsRubyDatabaseDriverWrapper::Host::HostInfo::NO_PORT
    )
  end

  def mysql_host_info
    AwsRubyDatabaseDriverWrapper::Host::HostInfo.new(
      host: MYSQL_HOST,
      port: AwsRubyDatabaseDriverWrapper::Host::HostInfo::NO_PORT
    )
  end

  def gdb_host_info
    AwsRubyDatabaseDriverWrapper::Host::HostInfo.new(
      host: GDB_HOST,
      port: AwsRubyDatabaseDriverWrapper::Host::HostInfo::NO_PORT
    )
  end

  def arbitrary_host_info(host)
    AwsRubyDatabaseDriverWrapper::Host::HostInfo.new(host:)
  end

  def base_pg_props
    {
      user: 'postgresqlUser',
      password: 'postgresqlPassword',
      wrapper_plugins: 'iam'
    }
  end

  def valid_token_entry(token = TEST_TOKEN)
    IAM_AUTH_UTILS::TokenEntry.new(
      token:,
      expires_at: Process.clock_gettime(Process::CLOCK_MONOTONIC) + 900
    )
  end

  let(:mock_storage_service) { instance_double(AwsRubyDatabaseDriverWrapper::Utils::Storage::StorageService) }
  let(:mock_db_dialect) { double('DbDialect') }
  let(:mock_dialect_service) do
    double('DialectService',
           db_dialect: mock_db_dialect,
           login_error?: false,
           driver_dialect: AwsRubyDatabaseDriverWrapper::DriverDialects::DriverDialectManager::PG_DIALECT)
  end
  let(:mock_service_container) do
    double('ServiceContainer',
           storage_service: mock_storage_service,
           dialect_service: mock_dialect_service)
  end

  let(:mock_credentials) { instance_double(Aws::Credentials, access_key_id: 'AKID', secret_access_key: 'SECRET') }
  let(:mock_rds_client_config) { double('RdsClientConfig', credentials: mock_credentials) }
  let(:mock_rds_client) { instance_double(Aws::RDS::Client, config: mock_rds_client_config) }
  let(:mock_token_generator) { instance_double(Aws::RDS::AuthTokenGenerator) }

  before do
    allow(Aws::CredentialProviderChain).to receive(:new).and_return(double(resolve: mock_credentials))
    allow(Aws::RDS::Client).to receive(:new).and_return(mock_rds_client)
    allow(Aws::RDS::AuthTokenGenerator).to receive(:new).and_return(mock_token_generator)
    allow(mock_token_generator).to receive(:auth_token).and_return(GENERATED_TOKEN)
    allow(mock_storage_service).to receive(:register)
    allow(mock_storage_service).to receive(:get).with(IAM_TOKEN_CACHE_NAME, anything).and_return(nil)
    allow(mock_storage_service).to receive(:set)
    allow(mock_db_dialect).to receive(:default_port).and_return(DEFAULT_PG_PORT)
    allow(mock_dialect_service).to receive(:driver_dialect)
      .and_return(AwsRubyDatabaseDriverWrapper::DriverDialects::DriverDialectManager::PG_DIALECT)
  end

  def build_plugin(wrapper_props = Concurrent::Map.new)
    described_class.new(mock_service_container, wrapper_props)
  end

  # Connects through the plugin, always raises inside the pipeline callable,
  # and returns the token written into props[:password].
  def connect_and_capture_token(plugin:, host_info:, props:)
    plugin.connect(host_info, props, true, -> { raise StandardError, 'simulated driver error' })
  rescue StandardError
    props[:password]
  end

  describe '#connect with valid cached token (PostgreSQL)' do
    it 'uses the cached token and does not call the token generator' do
      allow(mock_storage_service).to receive(:get).with(IAM_TOKEN_CACHE_NAME, PG_CACHE_KEY)
                                                  .and_return(valid_token_entry)

      token = connect_and_capture_token(plugin: build_plugin, host_info: pg_host_info, props: base_pg_props)

      expect(token).to eq(TEST_TOKEN)
      expect(mock_token_generator).not_to have_received(:auth_token)
    end
  end

  describe '#connect with valid cached token (MySQL)' do
    it 'uses the cached token and does not call the token generator' do
      allow(mock_db_dialect).to receive(:default_port).and_return(DEFAULT_MYSQL_PORT)
      allow(mock_storage_service).to receive(:get).with(IAM_TOKEN_CACHE_NAME, MYSQL_CACHE_KEY)
                                                  .and_return(valid_token_entry)

      props = base_pg_props.merge(user: 'mysqlUser', password: 'mysqlPassword')
      token = connect_and_capture_token(plugin: build_plugin, host_info: mysql_host_info, props:)

      expect(token).to eq(TEST_TOKEN)
      expect(mock_token_generator).not_to have_received(:auth_token)
    end
  end

  def wrapper_props_map(hash)
    map = Concurrent::Map.new
    hash.each { |k, v| map[k] = v }
    map
  end

  describe '#connect with invalid iam_port and host port set' do
    it 'falls back to the host port' do
      port_1234_cache_key = "us-east-2:#{PG_HOST}:1234:postgresqlUser"
      allow(mock_storage_service).to receive(:get).with(IAM_TOKEN_CACHE_NAME, port_1234_cache_key)
                                                  .and_return(valid_token_entry)

      props = base_pg_props
      token = connect_and_capture_token(plugin: build_plugin(wrapper_props_map(iam_port: '0')), host_info: pg_host_info(port: 1234), props:)

      expect(token).to eq(TEST_TOKEN)
    end
  end

  describe '#connect with invalid iam_port and no host port' do
    it 'falls back to the dialect default port' do
      cache_key = "us-east-2:#{PG_HOST}:#{DEFAULT_PG_PORT}:postgresqlUser"
      allow(mock_storage_service).to receive(:get).with(IAM_TOKEN_CACHE_NAME, cache_key)
                                                  .and_return(valid_token_entry)

      props = base_pg_props
      token = connect_and_capture_token(plugin: build_plugin(wrapper_props_map(iam_port: '0')), host_info: pg_host_info, props:)

      expect(token).to eq(TEST_TOKEN)
    end
  end

  describe '#connect with host port explicitly specified' do
    it 'uses the host port in the cache key' do
      port_1234_cache_key = "us-east-2:#{PG_HOST}:1234:postgresqlUser"
      allow(mock_storage_service).to receive(:get).with(IAM_TOKEN_CACHE_NAME, port_1234_cache_key)
                                                  .and_return(valid_token_entry)

      token = connect_and_capture_token(plugin: build_plugin, host_info: pg_host_info(port: 1234), props: base_pg_props)

      expect(token).to eq(TEST_TOKEN)
    end
  end

  describe '#connect with iam_port set to 9999' do
    it 'uses iam_port in the cache key, overriding the host port' do
      port_9999_cache_key = "us-east-2:#{PG_HOST}:9999:postgresqlUser"
      allow(mock_storage_service).to receive(:get).with(IAM_TOKEN_CACHE_NAME, port_9999_cache_key)
                                                  .and_return(valid_token_entry)

      props = base_pg_props
      token = connect_and_capture_token(plugin: build_plugin(wrapper_props_map(iam_port: '9999')), host_info: pg_host_info(port: 1234),
                                        props:)

      expect(token).to eq(TEST_TOKEN)
    end
  end

  describe '#connect with iam_region explicitly set' do
    it 'uses the specified region in the cache key' do
      us_west_host = 'pg.testdb.us-west-1.rds.amazonaws.com'
      us_west_cache_key = "us-west-1:#{us_west_host}:#{DEFAULT_PG_PORT}:postgresqlUser"
      allow(mock_storage_service).to receive(:get).with(IAM_TOKEN_CACHE_NAME, us_west_cache_key)
                                                  .and_return(valid_token_entry)

      props = base_pg_props
      token = connect_and_capture_token(plugin: build_plugin(wrapper_props_map(iam_region: 'us-west-1')),
                                        host_info: arbitrary_host_info(us_west_host),
                                        props:)

      expect(token).to eq(TEST_TOKEN)
    end
  end

  describe '#connect with expired token in cache' do
    it 'generates a new token and stores a TokenEntry' do
      allow(mock_storage_service).to receive(:get).with(IAM_TOKEN_CACHE_NAME, PG_CACHE_KEY).and_return(nil)

      token = connect_and_capture_token(plugin: build_plugin, host_info: pg_host_info, props: base_pg_props)

      expect(token).to eq(GENERATED_TOKEN)
      expect(mock_token_generator).to have_received(:auth_token).once
      expect(mock_storage_service).to have_received(:set).with(
        IAM_TOKEN_CACHE_NAME, PG_CACHE_KEY, having_attributes(token: GENERATED_TOKEN)
      )
    end
  end

  describe '#connect with empty cache' do
    it 'generates a token and writes a TokenEntry to the cache' do
      token = connect_and_capture_token(plugin: build_plugin, host_info: pg_host_info, props: base_pg_props)

      expect(token).to eq(GENERATED_TOKEN)
      expect(mock_token_generator).to have_received(:auth_token).once
      expect(mock_storage_service).to have_received(:set).with(
        IAM_TOKEN_CACHE_NAME, PG_CACHE_KEY, having_attributes(token: GENERATED_TOKEN)
      )
    end

    it 'passes the correct region, host, port, and user to auth_token' do
      connect_and_capture_token(plugin: build_plugin, host_info: pg_host_info, props: base_pg_props)

      expect(mock_token_generator).to have_received(:auth_token).with(
        region: 'us-east-2',
        endpoint: "#{PG_HOST}:#{DEFAULT_PG_PORT}",
        user_name: 'postgresqlUser'
      )
    end
  end

  describe '#connect with iam_host override' do
    it 'generates a token using the overridden host, not the connection host' do
      override_cache_key = "us-east-2:#{PG_HOST}:#{DEFAULT_PG_PORT}:postgresqlUser"
      allow(mock_storage_service).to receive(:get).with(IAM_TOKEN_CACHE_NAME, override_cache_key).and_return(nil)

      props = base_pg_props
      connect_and_capture_token(
        plugin: build_plugin(wrapper_props_map(iam_host: PG_HOST, iam_region: 'us-east-2')),
        host_info: arbitrary_host_info('8.8.8.8'), props:
      )

      expect(mock_token_generator).to have_received(:auth_token).with(hash_including(endpoint: "#{PG_HOST}:#{DEFAULT_PG_PORT}"))
    end
  end

  describe '#connect retry on login error with cached token' do
    it 'generates a fresh token and retries the connect callable' do
      allow(mock_storage_service).to receive(:get).with(IAM_TOKEN_CACHE_NAME, PG_CACHE_KEY)
                                                  .and_return(valid_token_entry)
      allow(mock_dialect_service).to receive(:login_error?).and_return(true)

      call_count = 0
      retrying_callable = lambda do
        call_count += 1
        raise StandardError, 'login failure' if call_count == 1

        :ok
      end

      result = build_plugin.connect(pg_host_info, base_pg_props, true, retrying_callable)

      expect(result).to eq(:ok)
      expect(call_count).to eq(2)
      expect(mock_token_generator).to have_received(:auth_token).once
    end

    it 'does not retry when the error is not a login error' do
      allow(mock_storage_service).to receive(:get).with(IAM_TOKEN_CACHE_NAME, PG_CACHE_KEY)
                                                  .and_return(valid_token_entry)
      allow(mock_dialect_service).to receive(:login_error?).and_return(false)

      call_count = 0
      always_failing = lambda do
        call_count += 1
        raise StandardError, 'network timeout'
      end

      expect do
        build_plugin.connect(pg_host_info, base_pg_props, true, always_failing)
      end.to raise_error(StandardError, 'network timeout')

      expect(call_count).to eq(1)
      expect(mock_token_generator).not_to have_received(:auth_token)
    end

    it 'does not retry when the token was freshly generated (not from cache)' do
      allow(mock_storage_service).to receive(:get).with(IAM_TOKEN_CACHE_NAME, PG_CACHE_KEY).and_return(nil)
      allow(mock_dialect_service).to receive(:login_error?).and_return(true)

      call_count = 0
      always_failing = lambda do
        call_count += 1
        raise StandardError, 'login failure'
      end

      expect do
        build_plugin.connect(pg_host_info, base_pg_props, true, always_failing)
      end.to raise_error(StandardError, 'login failure')

      expect(call_count).to eq(1)
    end
  end

  describe '#connect with missing user' do
    it 'raises IamAuthError when user is nil' do
      expect do
        build_plugin.connect(pg_host_info, base_pg_props.merge(user: nil), true, -> {})
      end.to raise_error(AwsRubyDatabaseDriverWrapper::Errors::IamAuthError, /user/)
    end

    it 'raises IamAuthError when user is an empty string' do
      expect do
        build_plugin.connect(pg_host_info, base_pg_props.merge(user: ''), true, -> {})
      end.to raise_error(AwsRubyDatabaseDriverWrapper::Errors::IamAuthError, /user/)
    end
  end

  describe '#connect when region cannot be determined' do
    it 'raises IamAuthError for a non-RDS hostname with no iam_region prop' do
      expect do
        build_plugin.connect(arbitrary_host_info('custom.internal.corp'), base_pg_props, true, -> {})
      end.to raise_error(AwsRubyDatabaseDriverWrapper::Errors::IamAuthError, /region/)
    end
  end

  describe 'cache key format' do
    it 'builds the key as region:host:port:user' do
      captured_key = nil
      allow(mock_storage_service).to receive(:set) { |_name, key, _value| captured_key = key }

      connect_and_capture_token(plugin: build_plugin, host_info: pg_host_info, props: base_pg_props)

      expect(captured_key).to eq(PG_CACHE_KEY)
    end
  end

  describe '#connect sets enable_cleartext_plugin for MySQL driver' do
    let(:mysql_dialect_service) do
      double('DialectService',
             db_dialect: mock_db_dialect,
             login_error?: false,
             driver_dialect: AwsRubyDatabaseDriverWrapper::DriverDialects::DriverDialectManager::MYSQL_DIALECT)
    end
    let(:mysql_service_container) do
      double('ServiceContainer',
             storage_service: mock_storage_service,
             dialect_service: mysql_dialect_service)
    end

    before { allow(mock_db_dialect).to receive(:default_port).and_return(DEFAULT_MYSQL_PORT) }

    it 'sets enable_cleartext_plugin: true in props before calling the pipeline' do
      observed_cleartext = nil
      props = base_pg_props.merge(user: 'mysqlUser')
      pipeline = lambda do
        observed_cleartext = props[:enable_cleartext_plugin]
        raise StandardError, 'simulated'
      end
      begin
        described_class.new(mysql_service_container).connect(mysql_host_info, props, true, pipeline)
      rescue StandardError
        nil
      end
      expect(observed_cleartext).to be true
    end

    it 'does not set enable_cleartext_plugin for PostgreSQL driver' do
      observed_cleartext = nil
      props = base_pg_props
      pipeline = lambda do
        observed_cleartext = props[:enable_cleartext_plugin]
        raise StandardError, 'simulated'
      end
      begin
        build_plugin.connect(pg_host_info, props, true, pipeline)
      rescue StandardError
        nil
      end
      expect(observed_cleartext).to be_nil
    end
  end

  describe '#connect with Global Database endpoint' do
    before do
      allow(mock_storage_service).to receive(:get).with(IAM_TOKEN_CACHE_NAME, GDB_CACHE_KEY).and_return(nil)
    end

    it 'calls region_for with RDS_GLOBAL_WRITER_CLUSTER rds_type' do
      allow(IAM_AUTH_UTILS).to receive(:region_for).and_return('us-east-1')

      connect_and_capture_token(plugin: build_plugin, host_info: gdb_host_info, props: base_pg_props)

      expect(IAM_AUTH_UTILS).to have_received(:region_for).with(
        host: GDB_HOST,
        props: anything,
        rds_type: RDS_URL_TYPE::RDS_GLOBAL_WRITER_CLUSTER,
        credentials_provider: anything,
        rds_client_func: anything
      )
    end

    it 'generates a token for the region returned by region_for' do
      allow(IAM_AUTH_UTILS).to receive(:region_for).and_return('us-east-1')

      connect_and_capture_token(plugin: build_plugin, host_info: gdb_host_info, props: base_pg_props)

      expect(mock_token_generator).to have_received(:auth_token).with(
        hash_including(region: 'us-east-1', endpoint: "#{GDB_HOST}:#{DEFAULT_PG_PORT}")
      )
    end

    it 'uses the GDB region in the cache key' do
      allow(IAM_AUTH_UTILS).to receive(:region_for).and_return('us-east-1')
      captured_key = nil
      allow(mock_storage_service).to receive(:set) { |_name, key, _value| captured_key = key }

      connect_and_capture_token(plugin: build_plugin, host_info: gdb_host_info, props: base_pg_props)

      expect(captured_key).to eq(GDB_CACHE_KEY)
    end

    it 'raises IamAuthError when region_for returns nil (GDB lookup fails)' do
      allow(IAM_AUTH_UTILS).to receive(:region_for).and_return(nil)

      expect do
        build_plugin.connect(gdb_host_info, base_pg_props, true, -> {})
      end.to raise_error(AwsRubyDatabaseDriverWrapper::Errors::IamAuthError, /region/)
    end

    it 'uses an explicit iam_region prop without calling describe_global_clusters' do
      allow(IAM_AUTH_UTILS).to receive(:region_from_global_cluster).and_call_original
      allow(IAM_AUTH_UTILS).to receive(:region_for).and_call_original

      gdb_explicit_cache_key = "eu-west-1:#{GDB_HOST}:#{DEFAULT_PG_PORT}:postgresqlUser"
      allow(mock_storage_service).to receive(:get).with(IAM_TOKEN_CACHE_NAME, gdb_explicit_cache_key)
                                                  .and_return(valid_token_entry)

      props = base_pg_props
      token = connect_and_capture_token(plugin: build_plugin(wrapper_props_map(iam_region: 'eu-west-1')), host_info: gdb_host_info, props:)

      expect(token).to eq(TEST_TOKEN)
      expect(IAM_AUTH_UTILS).not_to have_received(:region_from_global_cluster)
    end
  end

  describe '#internal_connect' do
    it 'applies the same token injection as connect' do
      allow(mock_storage_service).to receive(:get).with(IAM_TOKEN_CACHE_NAME, PG_CACHE_KEY)
                                                  .and_return(valid_token_entry)

      props = base_pg_props
      begin
        build_plugin.internal_connect(pg_host_info, props, nil, true,
                                      -> { raise StandardError, 'simulated' })
      rescue StandardError
        nil
      end

      expect(props[:password]).to eq(TEST_TOKEN)
    end

    it 'accepts nil wrapper_props and is_initial_connection without error' do
      props = base_pg_props
      expect do
        build_plugin.internal_connect(pg_host_info, props, nil, false,
                                      -> { raise StandardError, 'simulated' })
      end.to raise_error(StandardError, 'simulated')
    end

    it 'uses wrapper_props iam_host for token generation when provided' do
      override_host = 'override.testdb.us-east-2.rds.amazonaws.com'
      override_cache_key = "us-east-2:#{override_host}:#{DEFAULT_PG_PORT}:postgresqlUser"
      allow(mock_storage_service).to receive(:get).with(IAM_TOKEN_CACHE_NAME, override_cache_key)
                                                  .and_return(nil)

      wrapper_props_override = wrapper_props_map(iam_host: override_host)
      props = base_pg_props
      begin
        build_plugin.internal_connect(pg_host_info, props, wrapper_props_override, false,
                                      -> { raise StandardError, 'simulated' })
      rescue StandardError
        nil
      end

      expect(mock_token_generator).to have_received(:auth_token).with(
        hash_including(endpoint: "#{override_host}:#{DEFAULT_PG_PORT}")
      )
    end

    it 'falls back to host_info when wrapper_props has no iam_host' do
      captured_key = nil
      allow(mock_storage_service).to receive(:set) { |_name, key, _value| captured_key = key }

      props = base_pg_props
      begin
        build_plugin.internal_connect(pg_host_info, props, nil, false,
                                      -> { raise StandardError, 'simulated' })
      rescue StandardError
        nil
      end

      expect(captured_key).to eq(PG_CACHE_KEY)
    end
  end

  describe '#subscribed_methods' do
    it 'includes connect' do
      expect(build_plugin.subscribed_methods).to include('connect')
    end

    it 'includes internal_connect' do
      expect(build_plugin.subscribed_methods).to include('internal_connect')
    end

    it 'does not subscribe to execute' do
      expect(build_plugin.subscribed_methods).not_to include('execute')
    end
  end

  describe "PluginManager registration under code 'iam'" do
    it "is registered under the code 'iam'" do
      require 'aws_ruby_database_driver_wrapper/services/plugin_manager'
      plugin_classes = AwsRubyDatabaseDriverWrapper::Services::PluginManager.plugin_classes
      expect(plugin_classes['iam']).to eq(described_class)
    end

    it 'has weight 1800 (after failover, matching JDBC ConnectionPluginChainBuilder)' do
      require 'aws_ruby_database_driver_wrapper/services/plugin_manager'
      plugin_weights = AwsRubyDatabaseDriverWrapper::Services::PluginManager.plugin_weights
      expect(plugin_weights[described_class]).to eq(1800)
    end
  end

  describe '.clear_cache' do
    it 'delegates to the storage service with CACHE_NAME' do
      allow(mock_storage_service).to receive(:clear)
      described_class.clear_cache(mock_storage_service)
      expect(mock_storage_service).to have_received(:clear).with(IAM_TOKEN_CACHE_NAME)
    end
  end

  describe 'IamAuthUtils.parse_token_expiry' do
    let(:token_with_expiry) do
      'hostname:5432/?Action=connect&DBUser=user&X-Amz-Algorithm=AWS4-HMAC-SHA256' \
        '&X-Amz-Credential=FAKE%2F20260622%2Fus-east-2%2Frds-db%2Faws4_request' \
        '&X-Amz-Date=20260622T000000Z&X-Amz-Expires=900&X-Amz-SignedHeaders=host' \
        '&X-Amz-Signature=fakesig'
    end

    let(:token_without_expiry) { 'hostname:5432/?Action=connect&DBUser=user' }

    it 'returns the parsed expiry in seconds when X-Amz-Expires is present' do
      expect(IAM_AUTH_UTILS.parse_token_expiry(token_with_expiry)).to eq(900)
    end

    it 'returns nil when X-Amz-Expires is absent' do
      expect(IAM_AUTH_UTILS.parse_token_expiry(token_without_expiry)).to be_nil
    end

    it 'returns nil for a malformed token string' do
      expect(IAM_AUTH_UTILS.parse_token_expiry('not a url at all @@@@')).to be_nil
    end
  end
end
