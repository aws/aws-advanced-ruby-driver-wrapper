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
require 'aws_ruby_database_driver_wrapper/plugins/kms_encryption/independent_connection_provider'
require 'aws_ruby_database_driver_wrapper/plugins/kms_encryption/metadata_manager'
require 'aws_ruby_database_driver_wrapper/plugins/kms_encryption/sql_runner'

RSpec.describe AwsRubyDatabaseDriverWrapper::Plugins::Encryption::MetadataManager do
  let(:encryption) { AwsRubyDatabaseDriverWrapper::Plugins::Encryption }
  let(:metadata_error) { AwsRubyDatabaseDriverWrapper::Errors::MetadataError }
  let(:connection) { double('Connection') }
  let(:connection_provider) { instance_double(encryption::IndependentConnectionProvider) }
  let(:sql_runner) { instance_double(encryption::SqlRunner) }
  # Background refresh off by default, so that an example only sees the queries it makes itself.
  let(:config) { build_encryption_config(metadata_cache_refresh_interval_sec: 0) }
  let(:rows) { [row('users', 'ssn'), row('users', 'email'), row('orders', 'card_number')] }
  subject(:manager) do
    described_class.new(connection_provider: connection_provider, sql_runner: sql_runner, config: config)
  end

  before do
    allow(connection_provider).to receive(:with_connection).and_yield(connection)
    allow(sql_runner).to receive(:query).and_return(rows)
    allow(sql_runner).to receive(:read_binary) { |value| value }
  end

  after { manager.shutdown }

  # One row of the encryption_metadata / key_storage join.
  def row(table_name, column_name, overrides = {})
    { 'table_name' => table_name, 'column_name' => column_name, 'encryption_algorithm' => 'AES-256-GCM',
      'key_id' => '3', 'created_at' => '2026-01-02 03:04:05 UTC', 'updated_at' => '2026-01-02 03:04:05 UTC',
      'key_uuid' => 'key-uuid', 'name' => "#{table_name}.#{column_name}",
      'master_key_arn' => 'arn:aws:kms:us-east-1:1:key/abcd', 'encrypted_data_key' => 'AQIDAHj...',
      'hmac_key' => 'h' * 32, 'key_spec' => 'AES_256', 'key_created_at' => '2026-01-02 03:04:05 UTC',
      'last_used_at' => '2026-01-02 03:04:05 UTC' }.merge(overrides)
  end

  describe '#start' do
    it 'loads the cache' do
      manager.start

      expect(manager.cache_size).to eq(3)
      expect(manager.last_refresh_time).to be_a(Time)
    end

    it 'does not load anything when the metadata is not cached' do
      manager = described_class.new(connection_provider: connection_provider, sql_runner: sql_runner,
                                    config: config.with(metadata_cache_enabled: false))
      manager.start

      expect(sql_runner).not_to have_received(:query)
      expect(manager.cache_size).to eq(0)
    end

    # A column can be added to or removed from the kms_encryption configuration while the application
    # runs, so the cache is reloaded periodically.
    it 'refreshes the cache in the background when an interval is configured' do
      manager = described_class.new(connection_provider: connection_provider, sql_runner: sql_runner,
                                    config: config.with(metadata_cache_refresh_interval_sec: 1))
      manager.start
      refresh_thread = Thread.list.find { |thread| thread.name == 'kms_encryption-metadata-refresh' }

      expect(refresh_thread).to be_alive
      manager.shutdown
      expect(refresh_thread).not_to be_alive
    end

    it 'starts no refresh thread when no interval is configured' do
      manager.start
      expect(Thread.list.map(&:name)).not_to include('kms_encryption-metadata-refresh')
    end

    it 'fails when the metadata cannot be loaded' do
      allow(sql_runner).to receive(:query).and_raise(StandardError, 'relation does not exist')

      expect { manager.start }
        .to raise_error(metadata_error, /Failed to load kms_encryption metadata: relation does not exist/) do |error|
          expect(error.code).to eq(metadata_error::METADATA_LOAD_FAILED)
        end
    end
  end

  describe '#refresh' do
    it 'replaces the cache with what the database now says' do
      manager.start
      allow(sql_runner).to receive(:query).and_return([row('users', 'ssn')])

      expect(manager.refresh).to eq(1)
      expect(manager.cache_size).to eq(1)
      expect(manager.column_encrypted?('users', 'email')).to be(false)
    end

    it 'reads every column configuration in one query' do
      manager.refresh

      expect(sql_runner).to have_received(:query)
        .with(connection, /FROM encrypt\.encryption_metadata em LEFT JOIN encrypt\.key_storage ks/)
    end

    it 'records the refresh in the audit trail' do
      audit_logger = instance_double(encryption::AuditLogger)
      allow(audit_logger).to receive(:log_metadata_operation)
      manager = described_class.new(connection_provider: connection_provider, sql_runner: sql_runner, config: config,
                                    audit_logger: audit_logger)
      manager.refresh

      expect(audit_logger).to have_received(:log_metadata_operation).with(operation: 'refresh', success: true)
    end

    it 'records a failed refresh in the audit trail' do
      audit_logger = instance_double(encryption::AuditLogger)
      allow(audit_logger).to receive(:log_metadata_operation)
      allow(sql_runner).to receive(:query).and_raise(StandardError, 'relation does not exist')
      manager = described_class.new(connection_provider: connection_provider, sql_runner: sql_runner, config: config,
                                    audit_logger: audit_logger)

      expect { manager.refresh }.to raise_error(metadata_error)
      expect(audit_logger).to have_received(:log_metadata_operation)
        .with(hash_including(operation: 'refresh', success: false))
    end
  end

  describe '#load_metadata' do
    it 'keys the configurations by table and column' do
      expect(manager.load_metadata.keys).to eq(['users.ssn', 'users.email', 'orders.card_number'])
    end

    it 'is empty when no column is configured for kms_encryption' do
      allow(sql_runner).to receive(:query).and_return([])
      expect(manager.load_metadata).to eq({})
    end

    it 'builds the column configuration and the key it points at' do
      column_config = manager.load_metadata['users.ssn']

      expect(column_config.table_name).to eq('users')
      expect(column_config.column_name).to eq('ssn')
      expect(column_config.algorithm).to eq('AES-256-GCM')
      expect(column_config.key_id).to eq(3)
      expect(column_config.created_at).to eq(Time.utc(2026, 1, 2, 3, 4, 5))
      expect(column_config.usable?).to be(true)

      key_metadata = column_config.key_metadata
      expect(key_metadata.id).to eq(3)
      expect(key_metadata.key_id).to eq('key-uuid')
      expect(key_metadata.key_name).to eq('users.ssn')
      expect(key_metadata.master_key_arn).to eq('arn:aws:kms:us-east-1:1:key/abcd')
      expect(key_metadata.encrypted_data_key).to eq('AQIDAHj...')
      expect(key_metadata.hmac_key).to eq('h' * 32)
    end

    it 'falls back to the default algorithm and key spec when the columns are null' do
      allow(sql_runner).to receive(:query)
        .and_return([row('users', 'ssn', { 'encryption_algorithm' => nil, 'key_spec' => nil })])
      column_config = manager.load_metadata['users.ssn']

      expect(column_config.algorithm).to eq(encryption::EncryptionAlgorithm::DEFAULT)
      expect(column_config.key_metadata.key_spec).to eq(encryption::KeyMetadata::DEFAULT_KEY_SPEC)
    end

    # The timestamp columns are nullable, so a row without them yields nil rather than raising.
    it 'yields nil timestamps when the row has null timestamp columns' do
      allow(sql_runner).to receive(:query).and_return(
        [row('users', 'ssn', { 'created_at' => nil, 'updated_at' => nil, 'key_created_at' => nil, 'last_used_at' => nil })]
      )
      column_config = manager.load_metadata['users.ssn']

      expect(column_config.created_at).to be_nil
      expect(column_config.updated_at).to be_nil
      expect(column_config.key_metadata.created_at).to be_nil
      expect(column_config.key_metadata.last_used_at).to be_nil
    end

    # The LEFT JOIN to key_storage keeps a column whose key row is missing, so it is still reported
    # as encrypted but with blank key material, which fails validation and so blocks the write.
    it 'still reports a column as encrypted when its key_storage join is null' do
      allow(sql_runner).to receive(:query).and_return(
        [row('users', 'ssn', { 'key_uuid' => nil, 'name' => nil, 'master_key_arn' => nil, 'encrypted_data_key' => nil,
                               'hmac_key' => nil, 'key_spec' => nil, 'key_created_at' => nil, 'last_used_at' => nil })]
      )
      column_config = manager.load_metadata['users.ssn']

      expect(column_config).not_to be_nil
      expect(column_config.column_identifier).to eq('users.ssn')
      expect(column_config.usable?).to be(false)
      expect(column_config.key_metadata.master_key_arn).to be_nil
      expect(column_config.key_metadata.encrypted_data_key).to be_nil
      expect(column_config.key_metadata.valid?).to be(false)
    end

    # The HMAC key is a bytea or blob column, so it goes through the driver specific reader.
    it 'reads the HMAC key as binary' do
      manager.load_metadata
      expect(sql_runner).to have_received(:read_binary).with('h' * 32).at_least(:once)
    end
  end

  describe '#column_encrypted?' do
    before { manager.start }

    it 'is true for a configured column' do
      expect(manager.column_encrypted?('users', 'ssn')).to be(true)
    end

    it 'is false for a column that is not configured' do
      expect(manager.column_encrypted?('users', 'name')).to be(false)
      expect(manager.column_encrypted?('audit_log', 'ssn')).to be(false)
    end

    it 'is false when either name is missing' do
      expect(manager.column_encrypted?(nil, 'ssn')).to be(false)
      expect(manager.column_encrypted?('users', nil)).to be(false)
    end

    # Every intercepted statement asks about its columns, so the answer must come from memory.
    it 'answers from the cache without querying' do
      3.times { manager.column_encrypted?('users', 'ssn') }
      expect(sql_runner).to have_received(:query).once
    end
  end

  describe '#column_config' do
    before { manager.start }

    it 'returns the configuration of a configured column' do
      expect(manager.column_config('users', 'ssn').column_identifier).to eq('users.ssn')
    end

    it 'is nil for a column that is not configured' do
      expect(manager.column_config('users', 'name')).to be_nil
    end

    it 'is nil when either name is missing' do
      expect(manager.column_config(nil, 'ssn')).to be_nil
      expect(manager.column_config('users', nil)).to be_nil
    end
  end

  describe '#table_configs' do
    before { manager.start }

    # A read is planned from this: the statement says which tables it touches, and this says which
    # of their columns will come back encrypted.
    it 'returns every encrypted column of the table' do
      expect(manager.table_configs('users').map(&:column_name)).to contain_exactly('ssn', 'email')
    end

    it 'is empty for a table with no encrypted column' do
      expect(manager.table_configs('audit_log')).to eq([])
    end

    it 'is empty when no table was named' do
      expect(manager.table_configs(nil)).to eq([])
    end
  end

  describe 'looking up a column without a usable cache' do
    subject(:manager) do
      described_class.new(connection_provider: connection_provider, sql_runner: sql_runner,
                          config: config.with(metadata_cache_enabled: false))
    end

    it 'asks the database whether the column is encrypted' do
      allow(sql_runner).to receive(:query).and_return([{ '1' => 1 }])

      expect(manager.column_encrypted?('users', 'ssn')).to be(true)
      expect(sql_runner).to have_received(:query)
        .with(connection, /SELECT 1 FROM encrypt\.encryption_metadata/, %w[users ssn])
    end

    it 'is false when the database has no row for the column' do
      allow(sql_runner).to receive(:query).and_return([])
      expect(manager.column_encrypted?('users', 'ssn')).to be(false)
    end

    it 'asks the database for the column configuration' do
      allow(sql_runner).to receive(:query).and_return([row('users', 'ssn')])

      expect(manager.column_config('users', 'ssn').column_identifier).to eq('users.ssn')
      expect(sql_runner).to have_received(:query)
        .with(connection, /WHERE em\.table_name = \? AND em\.column_name = \?/, %w[users ssn])
    end

    it 'is nil when the database has no configuration for the column' do
      allow(sql_runner).to receive(:query).and_return([])
      expect(manager.column_config('users', 'ssn')).to be_nil
    end

    it 'asks the database for the columns of a table' do
      allow(sql_runner).to receive(:query).and_return([row('users', 'ssn'), row('users', 'email')])

      expect(manager.table_configs('users').map(&:column_name)).to eq(%w[ssn email])
      expect(sql_runner).to have_received(:query).with(connection, /WHERE em\.table_name = \?/, ['users'])
    end

    it 'reports a failed lookup, naming the column it was about' do
      allow(sql_runner).to receive(:query).and_raise(StandardError, 'relation does not exist')

      expect { manager.column_config('users', 'ssn') }
        .to raise_error(metadata_error, /Failed to load the kms_encryption configuration/) do |error|
          expect(error.code).to eq(metadata_error::METADATA_LOOKUP_FAILED)
          expect(error.context).to include(table: 'users', column: 'ssn')
        end

      expect { manager.column_encrypted?('users', 'ssn') }.to raise_error(metadata_error)
      expect { manager.table_configs('users') }
        .to raise_error(metadata_error) { |error| expect(error.context).to include(table: 'users') }
    end
  end

  describe 'a cache that has expired' do
    subject(:manager) do
      described_class.new(connection_provider: connection_provider, sql_runner: sql_runner,
                          config: config.with(metadata_cache_expiration_sec: 1))
    end

    # An expired cache could be answering with a configuration that has since been changed.
    it 'goes back to the database rather than answering from stale entries' do
      manager.start
      manager.instance_variable_set(:@last_refresh_time, Time.now - 60)
      allow(sql_runner).to receive(:query).and_return([])

      expect(manager.column_encrypted?('users', 'ssn')).to be(false)
      expect(sql_runner).to have_received(:query)
        .with(connection, /SELECT 1 FROM encrypt\.encryption_metadata/, %w[users ssn])
    end
  end

  describe '#shutdown' do
    it 'empties the cache' do
      manager.start
      manager.shutdown

      expect(manager.cache_size).to eq(0)
      expect(manager.last_refresh_time).to be_nil
    end

    it 'can be called before a start, and twice over' do
      expect { manager.shutdown }.not_to raise_error
      manager.start
      manager.shutdown
      expect { manager.shutdown }.not_to raise_error
    end
  end
end
