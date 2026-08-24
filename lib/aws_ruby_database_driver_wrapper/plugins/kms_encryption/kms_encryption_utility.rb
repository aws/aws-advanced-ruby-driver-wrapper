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

require_relative '../../logging'
require_relative '../../property_definition'
require_relative 'audit_logger'
require_relative 'data_key_cache'
require_relative 'encryption_config'
require_relative 'encryption_service'
require_relative 'errors'
require_relative 'independent_connection_provider'
require_relative 'key_management_utility'
require_relative 'key_manager'
require_relative 'metadata_manager'
require_relative 'schema_validator'
require_relative 'sql_runner'

module AwsRubyDatabaseDriverWrapper
  module Plugins
    module Encryption
      # Wires up everything the kms_encryption plugin needs and owns its lifecycle.
      #
      # Construction is split in two, because the two halves become available at different times:
      #
      # * Everything that only needs properties (the configuration, the audit logger, the data key
      #   cache, the KMS client) is built up front, so that a misconfiguration is reported when the
      #   connection is opened rather than in the middle of a query.
      # * Everything that needs to talk to the database (the metadata manager and the key manager,
      #   both of which read the +encryption_metadata+ and +key_storage+ tables) is built the first
      #   time a statement could touch an encrypted column, through {#ensure_initialized}. At that
      #   point the connect pipeline has finished, so the plugin can open its own connections.
      #
      # The KMS client is created lazily as well, so that an application that never touches an
      # encrypted column never has to reach KMS.
      class KmsEncryptionUtility
        include Logging

        PLUGIN_NAME = 'KmsEncryptionPlugin'

        attr_reader :config, :audit_logger, :data_key_cache

        # @param service_container [Services::ServiceContainer]
        # @param props [Concurrent::Map, Hash] the wrapper properties
        # @param kms_client [Aws::KMS::Client, nil] a client to use instead of building one
        # @raise [ArgumentError] if the kms_encryption properties are invalid
        def initialize(service_container, props, kms_client: nil)
          raise ArgumentError, 'service_container is required' if service_container.nil?

          @service_container = service_container
          @props = props
          @config = EncryptionConfig.from_props(props)
          @kms_client = kms_client
          @lock = Mutex.new
          @initialized = false
          @closed = false

          @audit_logger = AuditLogger.new(@config.audit_logging_enabled)
          @data_key_cache = DataKeyCache.new(
            max_size: @config.data_key_cache_max_size,
            ttl_sec: @config.data_key_cache_expiration_sec,
            enabled: @config.data_key_cache_enabled
          )

          logger.debug do
            "Loaded the kms_encryption configuration: region=#{@config.kms_region}, " \
              "schema=#{@config.metadata_schema}, metadata cache=#{@config.metadata_cache_enabled}, " \
              "max retries=#{@config.key_management_max_retries}"
          end
        end

        # @return [String] the name the plugin is known by
        def plugin_name
          PLUGIN_NAME
        end

        # @return [Boolean] whether the database backed components have been built
        def initialized?
          @lock.synchronize { @initialized }
        end

        # @return [Boolean] whether {#cleanup} has run
        def closed?
          @lock.synchronize { @closed }
        end

        # Builds the components that need a database connection, the first time one is needed.
        #
        # @return [void]
        # @raise [Errors::MetadataError] if the initial metadata load fails
        # @raise [Errors::EncryptionPluginError] if the components cannot be built
        def ensure_initialized
          return if @lock.synchronize { @initialized || @closed }

          @lock.synchronize do
            next if @initialized || @closed

            build_database_components
            @initialized = true
          end
          nil
        end

        # @return [MetadataManager, nil] nil until {#ensure_initialized} has run
        def metadata_manager
          @lock.synchronize { @metadata_manager }
        end

        # @return [KeyManager, nil] nil until {#ensure_initialized} has run
        def key_manager
          @lock.synchronize { @key_manager }
        end

        # @return [SqlRunner, nil] nil until {#ensure_initialized} has run
        def sql_runner
          @lock.synchronize { @sql_runner }
        end

        # @return [IndependentConnectionProvider, nil] nil until {#ensure_initialized} has run
        def connection_provider
          @lock.synchronize { @connection_provider }
        end

        # The administrative interface, for setting up and rotating keys.
        #
        # @return [KeyManagementUtility]
        # @raise [Errors::EncryptionPluginError] if the components cannot be built
        def key_management_utility
          ensure_initialized
          @lock.synchronize { @key_management_utility }
        end

        # Checks that the +encryption_metadata+ and +key_storage+ tables look the way the plugin
        # expects. Nothing calls this automatically: it is meant for setup scripts and diagnostics.
        #
        # @return [SchemaValidator::ValidationResult]
        # @raise [Errors::EncryptionPluginError] if the components cannot be built
        def validate_schema
          ensure_initialized
          validator = @lock.synchronize { @schema_validator }
          provider = @lock.synchronize { @connection_provider }

          provider.with_connection(operation: 'VALIDATE_SCHEMA') { |connection| validator.validate(connection) }
        end

        # The KMS client, created on first use.
        #
        # @return [Aws::KMS::Client]
        def kms_client
          @lock.synchronize { @kms_client ||= create_kms_client }
        end

        # @return [Boolean] whether the plugin reads its metadata over its own connections
        def using_independent_connections?
          !connection_provider.nil?
        end

        # @return [String] a description of how metadata is being read
        def connection_mode_status
          if using_independent_connections?
            'The kms_encryption plugin is reading its metadata over independent connections'
          else
            'The kms_encryption plugin has not opened a metadata connection yet'
          end
        end

        # Logs the connection mode and the metadata connection counters, for troubleshooting.
        # @return [void]
        def log_current_status
          logger.info("#{PLUGIN_NAME} status report")
          logger.info(connection_mode_status)
          connection_provider&.log_health_status
          nil
        end

        # Releases everything the plugin holds: the background metadata refresh, the cached data
        # keys, and the KMS client.
        #
        # @return [void]
        def cleanup
          return if @lock.synchronize { @closed }

          logger.debug("Cleaning up #{PLUGIN_NAME}")

          metadata_manager, connection_provider, data_key_cache, kms_client = @lock.synchronize do
            @closed = true
            @initialized = false
            [@metadata_manager, @connection_provider, @data_key_cache, @kms_client]
          end

          quietly('log the metadata connection status') { connection_provider&.log_health_status }
          quietly('stop the metadata refresh') { metadata_manager&.shutdown }
          quietly('clear the data key cache') { data_key_cache&.shutdown }
          quietly('close the KMS client') { kms_client.close if kms_client.respond_to?(:close) }

          logger.debug("Finished cleaning up #{PLUGIN_NAME}")
          nil
        end

        private

        # Runs under @lock.
        def build_database_components
          @sql_runner = SqlRunner.new(@service_container.dialect_service.driver_dialect)
          @connection_provider = IndependentConnectionProvider.new(@service_container, audit_logger: @audit_logger)
          @audit_logger.log_connection_parameter_extraction(
            strategy: 'ServiceContainer', connection_type: 'INDEPENDENT_CONNECTION'
          )

          @kms_client ||= create_kms_client
          @key_manager = KeyManager.new(
            kms_client: @kms_client,
            connection_provider: @connection_provider,
            sql_runner: @sql_runner,
            config: @config,
            data_key_cache: @data_key_cache,
            audit_logger: @audit_logger
          )
          @metadata_manager = MetadataManager.new(
            connection_provider: @connection_provider,
            sql_runner: @sql_runner,
            config: @config,
            audit_logger: @audit_logger
          )
          @schema_validator = SchemaValidator.new(@config.metadata_schema, @sql_runner)
          @key_management_utility = KeyManagementUtility.new(
            key_manager: @key_manager,
            metadata_manager: @metadata_manager,
            connection_provider: @connection_provider,
            sql_runner: @sql_runner,
            kms_client: @kms_client,
            config: @config,
            audit_logger: @audit_logger
          )

          @metadata_manager.start
          logger.debug('The kms_encryption plugin is ready to encrypt and decrypt column values')
        end

        def create_kms_client
          ensure_sdk!
          logger.debug { "Creating a KMS client for region #{@config.kms_region}" }

          options = {
            region: @config.kms_region,
            credentials: PropertyDefinition::AWS_CREDENTIALS_PROVIDER.get(@props) ||
                         Aws::CredentialProviderChain.new.resolve
          }
          options[:endpoint] = @config.kms_endpoint unless @config.kms_endpoint.nil?

          Aws::KMS::Client.new(**options)
        end

        def ensure_sdk!
          require 'aws-sdk-kms'
        rescue LoadError
          raise LoadError,
                "The KMS kms_encryption plugin requires 'aws-sdk-kms'. " \
                "Add it to your Gemfile: gem 'aws-sdk-kms'"
        end

        # Cleanup must release everything it can, so one failing step cannot stop the others.
        def quietly(description)
          yield
        rescue StandardError => e
          logger.warn("Failed to #{description} while cleaning up the kms_encryption plugin: #{e.message}")
        end
      end
    end
  end
end
