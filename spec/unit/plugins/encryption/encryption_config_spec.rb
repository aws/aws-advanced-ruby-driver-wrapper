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
require 'aws_ruby_database_driver_wrapper/plugins/kms_encryption/encryption_config'

RSpec.describe AwsRubyDatabaseDriverWrapper::Plugins::Encryption::EncryptionConfig do
  let(:schema_name_class) { AwsRubyDatabaseDriverWrapper::Plugins::Encryption::SchemaName }

  def props(values = {})
    map = Concurrent::Map.new
    values.each { |key, value| map[key] = value }
    map
  end

  def build_config(overrides = {})
    build_encryption_config(overrides)
  end

  # The region falls back to the environment, which the test host may well have set.
  def without_region_env
    allow(ENV).to receive(:fetch).and_call_original
    allow(ENV).to receive(:fetch).with('AWS_REGION', nil).and_return(nil)
    allow(ENV).to receive(:fetch).with('AWS_DEFAULT_REGION', nil).and_return(nil)
  end

  describe '.from_props' do
    it 'applies the default for every setting' do
      config = described_class.from_props(props(encryption_kms_region: 'us-east-1'))

      expect(config.kms_endpoint).to be_nil
      expect(config.metadata_schema).to eq(schema_name_class.of('encrypt'))
      expect(config.metadata_cache_enabled).to be(true)
      expect(config.metadata_cache_expiration_sec).to eq(3600)
      expect(config.metadata_cache_refresh_interval_sec).to eq(300)
      expect(config.key_management_max_retries).to eq(3)
      expect(config.key_management_retry_backoff_base_ms).to eq(100)
      expect(config.audit_logging_enabled).to be(false)
      expect(config.data_key_cache_enabled).to be(true)
      expect(config.data_key_cache_max_size).to eq(1000)
      expect(config.data_key_cache_expiration_sec).to eq(3600)
    end

    it 'reads every setting from the properties' do
      config = described_class.from_props(
        props(
          encryption_kms_region: 'eu-west-1',
          encryption_kms_endpoint: 'https://kms.local:4566',
          encryption_metadata_schema: 'vault',
          encryption_metadata_cache_enabled: false,
          encryption_metadata_cache_expiration_sec: 60,
          encryption_metadata_cache_refresh_interval_sec: 0,
          encryption_key_management_max_retries: 5,
          encryption_key_management_retry_backoff_base_ms: 250,
          encryption_audit_logging_enabled: true,
          encryption_data_key_cache_enabled: false,
          encryption_data_key_cache_max_size: 10,
          encryption_data_key_cache_expiration_sec: 120
        )
      )

      expect(config.kms_region).to eq('eu-west-1')
      expect(config.kms_endpoint).to eq('https://kms.local:4566')
      expect(config.metadata_schema).to eq(schema_name_class.of('vault'))
      expect(config.metadata_cache_enabled).to be(false)
      expect(config.metadata_cache_expiration_sec).to eq(60)
      expect(config.metadata_cache_refresh_interval_sec).to eq(0)
      expect(config.key_management_max_retries).to eq(5)
      expect(config.key_management_retry_backoff_base_ms).to eq(250)
      expect(config.audit_logging_enabled).to be(true)
      expect(config.data_key_cache_enabled).to be(false)
      expect(config.data_key_cache_max_size).to eq(10)
      expect(config.data_key_cache_expiration_sec).to eq(120)
    end

    it 'falls back to AWS_REGION' do
      allow(ENV).to receive(:fetch).and_call_original
      allow(ENV).to receive(:fetch).with('AWS_REGION', nil).and_return('ap-south-1')
      expect(described_class.from_props(props).kms_region).to eq('ap-south-1')
    end

    it 'falls back to AWS_DEFAULT_REGION' do
      allow(ENV).to receive(:fetch).and_call_original
      allow(ENV).to receive(:fetch).with('AWS_REGION', nil).and_return(nil)
      allow(ENV).to receive(:fetch).with('AWS_DEFAULT_REGION', nil).and_return('ap-south-1')
      expect(described_class.from_props(props).kms_region).to eq('ap-south-1')
    end

    it 'prefers an explicitly configured region over the environment' do
      allow(ENV).to receive(:fetch).and_call_original
      allow(ENV).to receive(:fetch).with('AWS_REGION', nil).and_return('ap-south-1')
      expect(described_class.from_props(props(encryption_kms_region: 'eu-west-1')).kms_region).to eq('eu-west-1')
    end

    # No region is assumed: like the JDBC wrapper, the configuration is rejected rather than
    # defaulting to a region when neither the property nor the environment supplies one.
    it 'raises when no region is configured and none is in the environment' do
      without_region_env
      expect { described_class.from_props(props) }
        .to raise_error(ArgumentError, /encryption_kms_region cannot be empty/)
    end

    it 'rejects a schema name that could not be used safely in a query' do
      expect { described_class.from_props(props(encryption_metadata_schema: 'encrypt;DROP TABLE users')) }
        .to raise_error(ArgumentError, /Invalid schema name/)
    end

    it 'rejects a value that is out of range' do
      expect { described_class.from_props(props(encryption_data_key_cache_max_size: 0)) }
        .to raise_error(ArgumentError, /encryption_data_key_cache_max_size must be a positive integer/)
    end
  end

  describe '#initialize' do
    it 'carries the property defaults for the settings that are not overridden' do
      config = build_config
      expect(config.metadata_cache_enabled).to be(true)
      expect(config.data_key_cache_max_size).to eq(1000)
    end

    it 'wraps a plain schema name' do
      expect(build_config(metadata_schema: 'vault').metadata_schema).to be_a(schema_name_class)
    end

    it 'accepts an already validated schema name' do
      schema = schema_name_class.of('vault')
      expect(build_config(metadata_schema: schema).metadata_schema).to be(schema)
    end

    it 'validates a copy made with #with' do
      expect { build_config.with(kms_region: '  ') }
        .to raise_error(ArgumentError, /encryption_kms_region cannot be empty/)
    end
  end

  describe '#background_refresh_enabled?' do
    it 'is true when the metadata is cached and an interval is set' do
      expect(build_config.background_refresh_enabled?).to be(true)
    end

    it 'is false when the metadata is not cached' do
      expect(build_config(metadata_cache_enabled: false).background_refresh_enabled?).to be(false)
    end

    it 'is false when the interval is zero' do
      expect(build_config(metadata_cache_refresh_interval_sec: 0).background_refresh_enabled?).to be(false)
    end
  end

  describe '#validate!' do
    it 'rejects a missing region, since every KMS call needs one' do
      expect { build_config(kms_region: '') }.to raise_error(ArgumentError, /encryption_kms_region cannot be empty/)
      expect { build_config(kms_region: nil) }.to raise_error(ArgumentError, /encryption_kms_region cannot be empty/)
    end

    it 'rejects a cache expiration that is not positive' do
      expect { build_config(metadata_cache_expiration_sec: 0) }
        .to raise_error(ArgumentError, /encryption_metadata_cache_expiration_sec must be a positive integer/)
      expect { build_config(data_key_cache_expiration_sec: -1) }
        .to raise_error(ArgumentError, /encryption_data_key_cache_expiration_sec must be a positive integer/)
    end

    # A zero refresh interval is how background refresh is turned off, so it has to be allowed.
    it 'rejects a negative refresh interval but allows zero' do
      expect { build_config(metadata_cache_refresh_interval_sec: -1) }
        .to raise_error(ArgumentError, /encryption_metadata_cache_refresh_interval_sec must be a non-negative integer/)
      expect { build_config(metadata_cache_refresh_interval_sec: 0) }.not_to raise_error
    end

    it 'rejects a negative retry count but allows zero' do
      expect { build_config(key_management_max_retries: -1) }
        .to raise_error(ArgumentError, /encryption_key_management_max_retries must be a non-negative integer/)
      expect { build_config(key_management_max_retries: 0) }.not_to raise_error
    end

    it 'rejects a backoff base that is not positive' do
      expect { build_config(key_management_retry_backoff_base_ms: 0) }
        .to raise_error(ArgumentError, /encryption_key_management_retry_backoff_base_ms must be a positive integer/)
    end

    it 'rejects a cache size that is not positive' do
      expect { build_config(data_key_cache_max_size: 0) }
        .to raise_error(ArgumentError, /encryption_data_key_cache_max_size must be a positive integer/)
    end

    it 'returns itself when everything is in range' do
      config = build_config
      expect(config.validate!).to be(config)
    end
  end
end
