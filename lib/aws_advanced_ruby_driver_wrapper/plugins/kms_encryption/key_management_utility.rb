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
require_relative 'encryption_algorithm'
require_relative 'encryption_service'
require_relative 'errors'
require_relative 'key_metadata'
require_relative 'sanitizer'

module AwsAdvancedRubyDriverWrapper
  module Plugins
    module Encryption
      # The administrative side of the plugin: creates master keys, turns kms_encryption on or off for a
      # column, rotates data keys, and reports which columns a key is used by.
      #
      # None of this runs during normal query execution. It is meant to be called once, from a
      # migration or a setup script, by whoever administers the kms_encryption configuration:
      #
      #   utility = plugin.key_management_utility
      #   arn = utility.create_master_key('application column kms_encryption')
      #   utility.initialize_encryption_for_column('users', 'ssn', arn)
      #
      # Rotating a data key only changes the key that new writes use. Values already written with
      # the previous key stay readable, because each stored value records the id of the key it was
      # written with and the read path resolves that key from +key_storage+ (which keeps the old
      # key). Re-encrypting old values under the new key is optional, and is the application's job;
      # until it is done, retiring the old key from +key_storage+ would make them unreadable.
      class KeyManagementUtility
        include Logging

        KEY_SPEC = 'AES_256'
        ALIAS_PREFIX = 'alias/ruby-kms_encryption-'

        # @param key_manager [KeyManager]
        # @param metadata_manager [MetadataManager]
        # @param connection_provider [IndependentConnectionProvider]
        # @param sql_runner [SqlRunner]
        # @param kms_client [Aws::KMS::Client]
        # @param config [EncryptionConfig]
        # @param audit_logger [AuditLogger, nil]
        def initialize(key_manager:, metadata_manager:, connection_provider:, sql_runner:, kms_client:, config:,
                       audit_logger: nil)
          @key_manager = key_manager
          @metadata_manager = metadata_manager
          @connection_provider = connection_provider
          @sql = sql_runner
          @kms_client = kms_client
          @config = config
          @audit_logger = audit_logger
        end

        # Creates a KMS master key for column kms_encryption and gives it an alias.
        #
        # @param description [String] the key description
        # @param key_policy [String, nil] a key policy document; KMS applies its default when omitted
        # @param create_alias [Boolean] whether to also create an alias for the new key
        # @return [String] the ARN of the new master key
        # @raise [Errors::KeyManagementError] if the key cannot be created
        def create_master_key(description, key_policy: nil, create_alias: true)
          raise ArgumentError, 'description is required' if description.nil?

          logger.info("Creating a KMS master key: #{Sanitizer.description(description)}")

          request = { description: description, key_usage: 'ENCRYPT_DECRYPT', key_spec: 'SYMMETRIC_DEFAULT' }
          request[:policy] = key_policy unless key_policy.nil? || key_policy&.strip&.empty?

          arn = @kms_client.create_key(**request).key_metadata.arn
          add_alias(arn) if create_alias

          @audit_logger&.log_key_creation(master_key_arn: arn, description: description, success: true)
          arn
        rescue StandardError => e
          raise e if e.is_a?(ArgumentError)

          @audit_logger&.log_key_creation(master_key_arn: nil, description: description, success: false,
                                          error_message: e.message)
          raise Errors::KeyManagementError.key_creation_failed("Failed to create the master key: #{e.message}")
        end

        # Sets up kms_encryption for a column that is not encrypted yet: generates a data key, stores it,
        # and records the column in +encryption_metadata+.
        #
        # @param table_name [String]
        # @param column_name [String]
        # @param master_key_arn [String]
        # @param algorithm [String] one of {EncryptionAlgorithm::ALL}
        # @return [Integer] the +key_storage.id+ of the new data key
        # @raise [Errors::KeyManagementError] if the column is already encrypted or the setup fails
        def initialize_encryption_for_column(table_name, column_name, master_key_arn,
                                             algorithm = EncryptionAlgorithm::DEFAULT)
          logger.info("Initializing kms_encryption for #{table_name}.#{column_name}")

          begin
            already_encrypted = @metadata_manager.column_encrypted?(table_name, column_name)
          rescue Errors::MetadataError => e
            raise Errors::KeyManagementError
              .key_creation_failed("Failed to check the kms_encryption status of the column: #{e.message}")
              .with_context(:table, table_name)
              .with_context(:column, column_name)
          end

          if already_encrypted
            raise Errors::KeyManagementError
              .key_creation_failed("Column #{table_name}.#{column_name} is already encrypted")
              .with_context(:table, table_name)
              .with_context(:column, column_name)
          end

          generate_and_store_data_key(table_name, column_name, master_key_arn, algorithm)
        end

        # Generates a data key for a column and records it, replacing any configuration the column
        # already has.
        #
        # @param table_name [String]
        # @param column_name [String]
        # @param master_key_arn [String]
        # @param algorithm [String]
        # @return [Integer] the +key_storage.id+ of the new data key
        # @raise [Errors::KeyManagementError] if the key cannot be generated or stored
        def generate_and_store_data_key(table_name, column_name, master_key_arn,
                                        algorithm = EncryptionAlgorithm::DEFAULT)
          raise ArgumentError, 'table_name is required' if table_name.nil?
          raise ArgumentError, 'column_name is required' if column_name.nil?
          raise ArgumentError, 'master_key_arn is required' if master_key_arn.nil?

          algorithm = EncryptionAlgorithm::DEFAULT if algorithm.nil? || algorithm.to_s.strip.empty?
          raise EncryptionAlgorithm.unsupported(algorithm) unless EncryptionAlgorithm.supported?(algorithm)

          stored = store_new_data_key(table_name, column_name, master_key_arn)
          store_encryption_metadata(table_name, column_name, algorithm, stored.id)
          @metadata_manager.refresh if @config.metadata_cache_enabled

          logger.info("Stored a data key for #{table_name}.#{column_name} as key_storage id #{stored.id}")
          stored.id
        rescue StandardError => e
          raise e if e.is_a?(ArgumentError) || e.is_a?(Errors::EncryptionPluginError)

          raise Errors::KeyManagementError
            .key_creation_failed("Failed to generate and store the data key: #{e.message}")
            .with_context(:table, table_name)
            .with_context(:column, column_name)
        end

        # Rotates the data key of an already encrypted column. New writes use the new key; values
        # written with the previous key remain readable.
        #
        # @param table_name [String]
        # @param column_name [String]
        # @param new_master_key_arn [String, nil] a different master key, or nil to keep the current one
        # @return [Integer] the +key_storage.id+ of the new data key
        # @raise [Errors::KeyManagementError] if the column is not encrypted or the rotation fails
        def rotate_data_key(table_name, column_name, new_master_key_arn = nil)
          raise ArgumentError, 'table_name is required' if table_name.nil?
          raise ArgumentError, 'column_name is required' if column_name.nil?

          logger.info("Rotating the data key for #{table_name}.#{column_name}")

          current = @metadata_manager.column_config(table_name, column_name)
          if current.nil?
            raise Errors::KeyManagementError
              .key_creation_failed("No kms_encryption configuration exists for #{table_name}.#{column_name}")
              .with_context(:table, table_name)
              .with_context(:column, column_name)
          end

          master_key_arn = new_master_key_arn || current.key_metadata&.master_key_arn
          stored = store_new_data_key(table_name, column_name, master_key_arn)
          update_encryption_metadata_key(table_name, column_name, stored.id)
          @metadata_manager.refresh if @config.metadata_cache_enabled

          logger.info(
            "Rotated the data key for #{table_name}.#{column_name} from key #{current.key_id} to #{stored.id}"
          )
          stored.id
        rescue StandardError => e
          raise e if e.is_a?(ArgumentError) || e.is_a?(Errors::EncryptionPluginError)

          raise Errors::KeyManagementError
            .key_creation_failed("Failed to rotate the data key: #{e.message}")
            .with_context(:table, table_name)
            .with_context(:column, column_name)
        end

        # Stops encrypting a column by deleting its row from +encryption_metadata+.
        #
        # The key itself is deliberately left in +key_storage+, so that values already written can
        # still be decrypted.
        #
        # @param table_name [String]
        # @param column_name [String]
        # @return [Boolean] true when a configuration row was removed
        # @raise [Errors::KeyManagementError] if the row cannot be removed
        def remove_encryption_for_column(table_name, column_name)
          raise ArgumentError, 'table_name is required' if table_name.nil?
          raise ArgumentError, 'column_name is required' if column_name.nil?

          logger.info("Removing the kms_encryption configuration for #{table_name}.#{column_name}")

          affected = @connection_provider.with_connection(operation: 'DELETE_ENCRYPTION_METADATA') do |connection|
            @sql.update(connection, delete_encryption_metadata_sql, [table_name, column_name])
          end

          if affected.zero?
            logger.warn("No kms_encryption configuration existed for #{table_name}.#{column_name}")
          else
            logger.info("Removed the kms_encryption configuration for #{table_name}.#{column_name}")
          end

          @metadata_manager.refresh if @config.metadata_cache_enabled
          @audit_logger&.log_metadata_operation(operation: 'remove', table_name: table_name, column_name: column_name)
          affected.positive?
        rescue StandardError => e
          raise e if e.is_a?(ArgumentError)

          raise Errors::KeyManagementError
            .key_storage_failed("Failed to remove the kms_encryption configuration: #{e.message}")
            .with_context(:table, table_name)
            .with_context(:column, column_name)
        end

        # Lists the columns that a stored key is used by, so that the effect of rotating or
        # retiring it can be seen up front.
        #
        # @param key_id [Integer] a +key_storage.id+ value
        # @return [Array<String>] +"table.column"+ identifiers
        # @raise [Errors::KeyManagementError] if the query fails
        def columns_using_key(key_id)
          raise ArgumentError, 'key_id is required' if key_id.nil?

          rows = @connection_provider.with_connection(operation: 'SELECT_COLUMNS_USING_KEY') do |connection|
            @sql.query(connection, select_columns_with_key_sql, [key_id])
          end

          rows.map { |row| "#{row['table_name']}.#{row['column_name']}" }
        rescue StandardError => e
          raise e if e.is_a?(ArgumentError)

          raise Errors::KeyManagementError
            .key_retrieval_failed("Failed to find the columns using the key: #{e.message}")
            .with_key_id(key_id.to_s)
        end

        # @param master_key_arn [String]
        # @return [Boolean] whether the master key exists, is enabled, and can encrypt and decrypt
        def validate_master_key(master_key_arn)
          raise ArgumentError, 'master_key_arn is required' if master_key_arn.nil?

          @key_manager.validate_master_key(master_key_arn)
        end

        private

        # Generates a data key through KMS and writes it to +key_storage+. The plaintext key is
        # wiped again immediately: nothing here needs to encrypt with it.
        #
        # @return [KeyMetadata] the stored data key, with its +id+ filled in
        def store_new_data_key(table_name, column_name, master_key_arn)
          generated = @key_manager.generate_data_key(master_key_arn)

          begin
            @key_manager.store_key_metadata(
              KeyMetadata.new(
                key_name: key_name_for(table_name, column_name),
                master_key_arn: master_key_arn,
                encrypted_data_key: generated.encrypted_data_key,
                hmac_key: generated.hmac_key,
                key_spec: KEY_SPEC
              )
            )
          ensure
            EncryptionService.wipe(generated.plaintext)
          end
        end

        def key_name_for(table_name, column_name)
          "key-#{table_name}-#{column_name}-#{(Time.now.to_f * 1000).to_i}"
        end

        def add_alias(key_arn)
          @kms_client.create_alias(
            alias_name: "#{ALIAS_PREFIX}#{(Time.now.to_f * 1000).to_i}",
            target_key_id: key_arn
          )
        rescue StandardError => e
          # An alias is a convenience, not a requirement: the key is usable by ARN either way.
          logger.warn("Created the master key but could not create an alias for it: #{e.message}")
        end

        def store_encryption_metadata(table_name, column_name, algorithm, key_id)
          now = Time.now
          @connection_provider.with_connection(operation: 'STORE_ENCRYPTION_METADATA') do |connection|
            @sql.update(connection, insert_encryption_metadata_sql,
                        [table_name, column_name, algorithm, key_id, now, now])
          end

          @audit_logger&.log_metadata_operation(operation: 'store', table_name: table_name, column_name: column_name)
          nil
        end

        def update_encryption_metadata_key(table_name, column_name, key_id)
          affected = @connection_provider.with_connection(operation: 'UPDATE_ENCRYPTION_METADATA') do |connection|
            @sql.update(connection, update_encryption_metadata_key_sql, [key_id, Time.now, table_name, column_name])
          end

          if affected.zero?
            raise Errors::KeyManagementError
              .key_storage_failed("No kms_encryption configuration row was updated for #{table_name}.#{column_name}")
              .with_context(:table, table_name)
              .with_context(:column, column_name)
          end

          @audit_logger&.log_metadata_operation(operation: 'update', table_name: table_name, column_name: column_name)
          nil
        end

        # Upserting keeps this idempotent, so re-running a setup script does not fail on a column
        # that is already configured. The driver dialect supplies its own upsert grammar.
        def insert_encryption_metadata_sql
          base = "INSERT INTO #{@config.metadata_schema}.encryption_metadata " \
                 '(table_name, column_name, encryption_algorithm, key_id, created_at, updated_at) ' \
                 'VALUES (?, ?, ?, ?, ?, ?)'
          clause = @sql.upsert_clause(%w[table_name column_name], %w[encryption_algorithm key_id updated_at])
          "#{base} #{clause}"
        end

        def update_encryption_metadata_key_sql
          "UPDATE #{@config.metadata_schema}.encryption_metadata SET key_id = ?, updated_at = ? " \
            'WHERE table_name = ? AND column_name = ?'
        end

        def select_columns_with_key_sql
          "SELECT table_name, column_name FROM #{@config.metadata_schema}.encryption_metadata WHERE key_id = ?"
        end

        def delete_encryption_metadata_sql
          "DELETE FROM #{@config.metadata_schema}.encryption_metadata " \
            'WHERE table_name = ? AND column_name = ?'
        end
      end
    end
  end
end
