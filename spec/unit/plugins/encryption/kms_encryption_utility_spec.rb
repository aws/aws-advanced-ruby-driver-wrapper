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
require 'aws-sdk-kms'
require 'aws_ruby_database_driver_wrapper/driver_dialects/pg_driver_dialect'
require 'aws_ruby_database_driver_wrapper/plugins/kms_encryption/kms_encryption_utility'
require 'aws_ruby_database_driver_wrapper/services/service_container'

RSpec.describe AwsRubyDatabaseDriverWrapper::Plugins::Encryption::KmsEncryptionUtility do
  let(:encryption) { AwsRubyDatabaseDriverWrapper::Plugins::Encryption }
  let(:services) { AwsRubyDatabaseDriverWrapper::Services }
  let(:kms_client) { instance_double(Aws::KMS::Client) }
  let(:driver_dialect) { AwsRubyDatabaseDriverWrapper::DriverDialects::PgDriverDialect.new }
  let(:host_info) { AwsRubyDatabaseDriverWrapper::Host::HostInfo.new(host: 'db.example.com', port: 5432) }
  # The dialect asks whether a connection is already finished before closing it, so a connection that
  # the utility opened for itself has to answer that as an open one would.
  let(:connection) { double('Connection', finished?: false, close: nil) }
  let(:plugin_manager) { instance_double(services::PluginManager, internal_connect: connection) }
  let(:service_container) do
    instance_double(services::ServiceContainer,
                    connection_service: instance_double(services::ConnectionService, current_host_info: host_info,
                                                                                     driver_props: { host: 'db' },
                                                                                     wrapper_props: props),
                    plugin_manager: plugin_manager,
                    dialect_service: instance_double(services::DialectService, driver_dialect: driver_dialect))
  end
  # Both caches are off, so that building the database backed components neither queries the
  # metadata tables nor leaves a cleanup thread behind.
  let(:props) do
    props = Concurrent::Map.new
    props[:encryption_kms_region] = 'us-west-2'
    props[:encryption_metadata_schema] = 'encrypt'
    props[:encryption_metadata_cache_enabled] = false
    props[:encryption_metadata_cache_refresh_interval_sec] = 0
    props[:encryption_data_key_cache_enabled] = false
    props
  end
  subject(:utility) { described_class.new(service_container, props, kms_client: kms_client) }

  after { utility.cleanup }

  describe '#initialize' do
    it 'needs a service container to connect through' do
      expect { described_class.new(nil, props) }.to raise_error(ArgumentError, /service_container is required/)
    end

    it 'resolves the configuration from the properties' do
      expect(utility.config.kms_region).to eq('us-west-2')
      expect(utility.config.metadata_schema.to_s).to eq('encrypt')
      expect(utility.config.metadata_cache_enabled).to be(false)
    end

    # Reporting a bad value when the connection is opened is far more useful than reporting it in
    # the middle of a statement, which is when the components that read it are built.
    it 'reports an invalid property right away' do
      invalid_props = Concurrent::Map.new
      invalid_props[:encryption_data_key_cache_max_size] = -1

      expect { described_class.new(service_container, invalid_props) }.to raise_error(ArgumentError)
    end

    it 'builds the audit logger and the data key cache from the configuration' do
      expect(utility.audit_logger.enabled?).to be(false)
      expect(utility.data_key_cache.enabled?).to be(false)
    end

    it 'turns the audit logger on when the properties ask for it' do
      props[:encryption_audit_logging_enabled] = true
      expect(described_class.new(service_container, props, kms_client: kms_client).audit_logger.enabled?).to be(true)
    end

    it 'has not built anything that needs a database yet' do
      expect(utility).not_to be_initialized
      expect(utility.metadata_manager).to be_nil
      expect(utility.key_manager).to be_nil
      expect(utility.sql_runner).to be_nil
      expect(utility.connection_provider).to be_nil
    end

    describe 'the metadata cache warning' do
      before { described_class.metadata_cache_warning_logged = false }

      # Disabling the cache makes the plugin open a metadata connection per statement, so it is worth
      # a warning - but only once, not on every connection.
      it 'warns once per process when the metadata cache is disabled' do
        allow(AwsRubyDatabaseDriverWrapper.logger).to receive(:warn)

        described_class.new(service_container, props, kms_client: kms_client)
        described_class.new(service_container, props, kms_client: kms_client)

        expect(AwsRubyDatabaseDriverWrapper.logger)
          .to have_received(:warn).with(/metadata cache is disabled/).once
      end

      it 'does not warn when the metadata cache is enabled' do
        allow(AwsRubyDatabaseDriverWrapper.logger).to receive(:warn)

        enabled_props = Concurrent::Map.new
        enabled_props[:encryption_kms_region] = 'us-west-2'
        enabled_props[:encryption_metadata_schema] = 'encrypt'
        enabled_props[:encryption_data_key_cache_enabled] = false
        described_class.new(service_container, enabled_props, kms_client: kms_client)

        expect(AwsRubyDatabaseDriverWrapper.logger)
          .not_to have_received(:warn).with(/metadata cache is disabled/)
      end
    end

    it 'is named after the plugin it belongs to' do
      expect(utility.plugin_name).to eq('KmsEncryptionPlugin')
      expect(described_class::PLUGIN_NAME).to eq('KmsEncryptionPlugin')
    end
  end

  describe '#ensure_initialized' do
    it 'builds the components that need a database connection' do
      utility.ensure_initialized

      expect(utility).to be_initialized
      expect(utility.sql_runner).to be_a(encryption::SqlRunner)
      expect(utility.connection_provider).to be_a(encryption::IndependentConnectionProvider)
      expect(utility.key_manager).to be_a(encryption::KeyManager)
      expect(utility.metadata_manager).to be_a(encryption::MetadataManager)
      expect(utility.key_management_utility).to be_a(encryption::KeyManagementUtility)
    end

    # The SQL the plugin runs itself has to be written for the driver the application connects with.
    it 'gives the SQL runner the dialect of the connection in use' do
      utility.ensure_initialized
      expect(utility.sql_runner.pg?).to be(true)
    end

    it 'loads the kms_encryption metadata' do
      metadata_manager = instance_double(encryption::MetadataManager, start: nil, shutdown: nil)
      allow(encryption::MetadataManager).to receive(:new).and_return(metadata_manager)

      utility.ensure_initialized

      expect(metadata_manager).to have_received(:start)
    end

    # Every intercepted statement calls this, so it has to be cheap after the first one.
    it 'builds the components only once' do
      allow(encryption::MetadataManager).to receive(:new).and_call_original

      3.times { utility.ensure_initialized }

      expect(encryption::MetadataManager).to have_received(:new).once
    end

    it 'records how the metadata connection is made in the audit trail' do
      allow(utility.audit_logger).to receive(:log_connection_parameter_extraction)
      utility.ensure_initialized

      expect(utility.audit_logger).to have_received(:log_connection_parameter_extraction)
        .with(strategy: 'ServiceContainer', connection_type: 'INDEPENDENT_CONNECTION')
    end

    it 'builds nothing once the plugin has been cleaned up' do
      utility.cleanup
      utility.ensure_initialized

      expect(utility).not_to be_initialized
      expect(utility.metadata_manager).to be_nil
    end

    it 'reports a metadata load that failed' do
      metadata_manager = instance_double(encryption::MetadataManager, shutdown: nil)
      allow(metadata_manager).to receive(:start)
        .and_raise(AwsRubyDatabaseDriverWrapper::Errors::MetadataError.load_failed('relation does not exist'))
      allow(encryption::MetadataManager).to receive(:new).and_return(metadata_manager)

      expect { utility.ensure_initialized }
        .to raise_error(AwsRubyDatabaseDriverWrapper::Errors::MetadataError, /relation does not exist/)
      expect(utility).not_to be_initialized
    end
  end

  describe '#key_management_utility' do
    # The administrative interface is normally the first thing a setup script reaches for, before
    # any statement has been intercepted.
    it 'builds the components if they are not built yet' do
      expect(utility.key_management_utility).to be_a(encryption::KeyManagementUtility)
      expect(utility).to be_initialized
    end
  end

  describe '#validate_schema' do
    let(:result) { encryption::SchemaValidator::ValidationResult.new }
    let(:schema_validator) { instance_double(encryption::SchemaValidator) }

    before do
      allow(encryption::SchemaValidator).to receive(:new).and_return(schema_validator)
      allow(schema_validator).to receive(:validate).and_return(result)
    end

    it 'validates the schema over its own connection' do
      expect(utility.validate_schema).to be(result)

      expect(schema_validator).to have_received(:validate).with(connection)
      expect(plugin_manager).to have_received(:internal_connect)
    end

    it 'builds the components if they are not built yet' do
      utility.validate_schema
      expect(utility).to be_initialized
    end

    it 'looks in the configured schema' do
      utility.validate_schema
      expect(encryption::SchemaValidator).to have_received(:new)
        .with(utility.config.metadata_schema, instance_of(encryption::SqlRunner))
    end
  end

  describe '#kms_client' do
    it 'uses the client it was given' do
      expect(utility.kms_client).to be(kms_client)
    end

    context 'when no client was given' do
      subject(:utility) { described_class.new(service_container, props) }

      let(:credentials) { double('Credentials') }

      before do
        allow(Aws::CredentialProviderChain).to receive(:new).and_return(double(resolve: credentials))
        allow(Aws::KMS::Client).to receive(:new).and_return(kms_client)
      end

      it 'creates one for the configured region' do
        expect(utility.kms_client).to be(kms_client)
        expect(Aws::KMS::Client).to have_received(:new).with(region: 'us-west-2', credentials: credentials)
      end

      it 'uses a custom endpoint when one is configured' do
        props[:encryption_kms_endpoint] = 'https://kms.local:4566'
        utility.kms_client

        expect(Aws::KMS::Client).to have_received(:new).with(hash_including(endpoint: 'https://kms.local:4566'))
      end

      it 'uses the credentials the application configured' do
        own_credentials = double('OwnCredentials')
        props[:aws_credentials_provider] = own_credentials
        utility.kms_client

        expect(Aws::KMS::Client).to have_received(:new).with(hash_including(credentials: own_credentials))
      end

      # An application that never touches an encrypted column never has to reach KMS.
      it 'is not created until it is asked for' do
        expect(Aws::KMS::Client).not_to have_received(:new)
      end

      it 'is created only once' do
        3.times { utility.kms_client }
        expect(Aws::KMS::Client).to have_received(:new).once
      end

      it 'is created while building the components, so that the key manager has one' do
        utility.ensure_initialized

        expect(Aws::KMS::Client).to have_received(:new).once
        expect(utility.kms_client).to be(kms_client)
      end
    end
  end

  describe '#connection_mode_status' do
    it 'says that no metadata connection has been made yet' do
      expect(utility.using_independent_connections?).to be(false)
      expect(utility.connection_mode_status).to eq('The kms_encryption plugin has not opened a metadata connection yet')
    end

    it 'says that the metadata is read over independent connections' do
      utility.ensure_initialized

      expect(utility.using_independent_connections?).to be(true)
      expect(utility.connection_mode_status)
        .to eq('The kms_encryption plugin is reading its metadata over independent connections')
    end
  end

  describe '#log_current_status' do
    it 'reports the connection mode and the metadata connection counters' do
      utility.ensure_initialized
      allow(utility.connection_provider).to receive(:log_health_status)
      expect(utility.send(:logger)).to receive(:info).with('KmsEncryptionPlugin status report')
      expect(utility.send(:logger)).to receive(:info).with(/reading its metadata over independent connections/)

      utility.log_current_status

      expect(utility.connection_provider).to have_received(:log_health_status)
    end

    it 'reports the connection mode before any connection was made' do
      allow(utility.send(:logger)).to receive(:info)
      expect { utility.log_current_status }.not_to raise_error
    end
  end

  describe '#cleanup' do
    let(:metadata_manager) { instance_double(encryption::MetadataManager, start: nil, shutdown: nil) }

    before { allow(encryption::MetadataManager).to receive(:new).and_return(metadata_manager) }

    it 'stops the metadata refresh and clears the cached data keys' do
      utility.ensure_initialized
      allow(utility.data_key_cache).to receive(:shutdown)

      utility.cleanup

      expect(utility).to be_closed
      expect(utility).not_to be_initialized
      expect(metadata_manager).to have_received(:shutdown)
      expect(utility.data_key_cache).to have_received(:shutdown)
    end

    it 'reports the metadata connection counters one last time' do
      utility.ensure_initialized
      allow(utility.connection_provider).to receive(:log_health_status)

      utility.cleanup

      expect(utility.connection_provider).to have_received(:log_health_status)
    end

    # A real KMS client has nothing to close, but a stubbed or wrapped one might.
    it 'closes a KMS client that can be closed' do
      closeable_client = double('KmsClient', close: nil)
      utility = described_class.new(service_container, props, kms_client: closeable_client)

      utility.cleanup

      expect(closeable_client).to have_received(:close)
    end

    # Cleanup runs while the connection is being closed, so what it can release it must release
    # even if something else it holds is already gone.
    it 'releases everything it can even when a step fails' do
      utility.ensure_initialized
      allow(metadata_manager).to receive(:shutdown).and_raise(StandardError, 'refresh thread already gone')
      allow(utility.data_key_cache).to receive(:shutdown)
      allow(utility.send(:logger)).to receive(:warn)

      utility.cleanup

      expect(utility.data_key_cache).to have_received(:shutdown)
      expect(utility.send(:logger)).to have_received(:warn)
        .with(/Failed to stop the metadata refresh while cleaning up the kms_encryption plugin: refresh thread already gone/)
    end

    it 'can be called before the components were built, and twice over' do
      expect { utility.cleanup }.not_to raise_error
      expect(utility).to be_closed
      expect { utility.cleanup }.not_to raise_error
      expect(metadata_manager).not_to have_received(:shutdown)
    end
  end
end
