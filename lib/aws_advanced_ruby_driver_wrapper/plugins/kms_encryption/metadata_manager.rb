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
require_relative '../../utils/conversion_utils'
require_relative 'column_encryption_config'
require_relative 'connection_source'
require_relative 'encryption_algorithm'
require_relative 'errors'
require_relative 'key_metadata'

module AwsAdvancedRubyDriverWrapper
  module Plugins
    module Encryption
      # Reads the +encryption_metadata+ table, which says which columns are encrypted and with
      # which key, and keeps the answers in a cache.
      #
      # The cache is loaded once at startup and then refreshed on a background thread every
      # +encryption_metadata_cache_refresh_interval_sec+, so that a column can be added to or
      # removed from the kms_encryption configuration without restarting the application. Lookups
      # fall back to querying the database directly when caching is disabled or the cache has
      # expired.
      class MetadataManager
        include Logging
        include Utils::ConversionUtils
        include ConnectionSource

        # How long {shutdown} waits for the refresh thread to finish.
        SHUTDOWN_TIMEOUT_SEC = 5

        # Exactly one of +connection+ or +service_container+ must be given (see {ConnectionSource}).
        #
        # @param sql_runner [SqlRunner]
        # @param config [EncryptionConfig]
        # @param connection [Object, nil] a caller-owned connection used for every operation
        # @param service_container [Services::ServiceContainer, nil] opens a short-lived connection per operation
        # @param audit_logger [AuditLogger, nil]
        def initialize(sql_runner:, config:, connection: nil, service_container: nil, audit_logger: nil)
          use_connection_source(connection: connection, service_container: service_container)
          @sql = sql_runner
          @config = config
          @audit_logger = audit_logger
          @cache = {}
          @lock = Mutex.new
          @last_refresh_time = nil
          @running = false
          @refresh_thread = nil
        end

        # Loads the cache and starts the background refresh.
        #
        # @return [void]
        # @raise [Errors::MetadataError] if the initial load fails
        def start
          logger.debug('Initializing the kms_encryption metadata manager')
          refresh if @config.metadata_cache_enabled
          start_refresh_thread if @config.background_refresh_enabled?
          nil
        end

        # Reloads every column configuration from the database and replaces the cache.
        #
        # @return [Integer] the number of cached column configurations
        # @raise [Errors::MetadataError] if the load fails
        def refresh
          metadata = load_metadata

          @lock.synchronize do
            @cache = metadata
            @last_refresh_time = Time.now
          end

          logger.debug { "Refreshed the kms_encryption metadata cache with #{metadata.size} column configuration(s)" }
          @audit_logger&.log_metadata_operation(operation: 'refresh', success: true)
          metadata.size
        rescue Errors::MetadataError => e
          @audit_logger&.log_metadata_operation(operation: 'refresh', success: false, error_message: e.message)
          raise
        end

        # Reads every column configuration from the database, without touching the cache.
        #
        # @return [Hash{String => ColumnEncryptionConfig}] keyed by +"table.column"+
        # @raise [Errors::MetadataError] if the load fails
        def load_metadata
          rows = with_connection(operation: 'LOAD_ENCRYPTION_METADATA') do |connection|
            @sql.query(connection, load_metadata_sql)
          end

          rows.each_with_object({}) do |row, metadata|
            column_config = to_column_config(row)
            metadata[column_config.column_identifier] = column_config
          end
        rescue StandardError => e
          raise e if e.is_a?(Errors::MetadataError)

          raise Errors::MetadataError.load_failed("Failed to load kms_encryption metadata: #{e.message}")
        end

        # @param table_name [String, nil]
        # @param column_name [String, nil]
        # @return [Boolean] whether the column is configured for kms_encryption
        # @raise [Errors::MetadataError] if the lookup has to hit the database and that fails
        def column_encrypted?(table_name, column_name)
          return false if table_name.nil? || column_name.nil?

          if cache_usable?
            hit = @lock.synchronize { @cache.key?(column_identifier(table_name, column_name)) }
            return hit
          end

          column_encrypted_in_database?(table_name, column_name)
        end

        # @param table_name [String, nil]
        # @param column_name [String, nil]
        # @return [ColumnEncryptionConfig, nil] the column's configuration, nil when not encrypted
        # @raise [Errors::MetadataError] if the lookup has to hit the database and that fails
        def column_config(table_name, column_name)
          return nil if table_name.nil? || column_name.nil?

          return @lock.synchronize { @cache[column_identifier(table_name, column_name)] } if cache_usable?

          column_config_from_database(table_name, column_name)
        end

        # Every encrypted column of one table.
        #
        # This is what a read is planned from: the statement says which tables it touches, and the
        # configuration says which of their columns will come back encrypted.
        #
        # @param table_name [String, nil]
        # @return [Array<ColumnEncryptionConfig>] empty when no column of the table is encrypted
        # @raise [Errors::MetadataError] if the lookup has to hit the database and that fails
        def table_configs(table_name)
          return [] if table_name.nil?

          return @lock.synchronize { cached_table_configs(table_name) } if cache_usable?

          table_configs_from_database(table_name)
        end

        # @return [Time, nil] when the cache was last refreshed, nil when it never was
        def last_refresh_time
          @lock.synchronize { @last_refresh_time }
        end

        # @return [Integer] the number of cached column configurations
        def cache_size
          @lock.synchronize { @cache.size }
        end

        # Stops the background refresh and empties the cache.
        # @return [void]
        def shutdown
          @running = false
          thread = @refresh_thread
          if thread
            thread.wakeup if thread.alive?
            thread.join(SHUTDOWN_TIMEOUT_SEC)
            @refresh_thread = nil
          end

          @lock.synchronize do
            @cache = {}
            @last_refresh_time = nil
          end
          nil
        end

        private

        def column_identifier(table_name, column_name)
          "#{table_name}.#{column_name}"
        end

        # The cache can only answer a lookup when it is enabled, has been loaded, and has not
        # expired.
        def cache_usable?
          return false unless @config.metadata_cache_enabled

          last_refresh = @lock.synchronize { @last_refresh_time }
          !last_refresh.nil? && (Time.now - last_refresh) < @config.metadata_cache_expiration_sec
        end

        def column_encrypted_in_database?(table_name, column_name)
          row = with_connection(operation: 'CHECK_COLUMN_ENCRYPTED') do |connection|
            @sql.query(connection, check_column_encrypted_sql, [table_name, column_name]).first
          end
          !row.nil?
        rescue StandardError => e
          raise lookup_error(e, table_name, column_name)
        end

        def column_config_from_database(table_name, column_name)
          row = with_connection(operation: 'GET_COLUMN_CONFIG') do |connection|
            @sql.query(connection, column_config_sql, [table_name, column_name]).first
          end
          row && to_column_config(row)
        rescue StandardError => e
          raise lookup_error(e, table_name, column_name)
        end

        # Callers hold {@lock}.
        def cached_table_configs(table_name)
          @cache.each_value.select { |config| config.table_name == table_name }
        end

        def table_configs_from_database(table_name)
          rows = with_connection(operation: 'GET_TABLE_CONFIGS') do |connection|
            @sql.query(connection, table_configs_sql, [table_name])
          end
          rows.map { |row| to_column_config(row) }
        rescue StandardError => e
          raise lookup_error(e, table_name, nil)
        end

        def lookup_error(error, table_name, column_name)
          return error if error.is_a?(Errors::MetadataError)

          Errors::MetadataError
            .lookup_failed("Failed to load the kms_encryption configuration: #{error.message}")
            .with_table(table_name)
            .with_column(column_name)
        end

        # Builds a {ColumnEncryptionConfig}, and the {KeyMetadata} it points at, from one joined row.
        def to_column_config(row)
          key_metadata = KeyMetadata.new(
            id: row['key_id']&.to_i,
            key_id: row['key_uuid'],
            key_name: row['name'],
            master_key_arn: row['master_key_arn'],
            encrypted_data_key: row['encrypted_data_key'],
            hmac_key: @sql.read_binary(row['hmac_key']),
            key_spec: row['key_spec'] || KeyMetadata::DEFAULT_KEY_SPEC,
            created_at: row['key_created_at'] && to_time(row['key_created_at']),
            last_used_at: row['last_used_at'] && to_time(row['last_used_at'])
          )

          ColumnEncryptionConfig.new(
            table_name: row['table_name'],
            column_name: row['column_name'],
            algorithm: row['encryption_algorithm'] || EncryptionAlgorithm::DEFAULT,
            key_id: row['key_id']&.to_i,
            key_metadata: key_metadata,
            created_at: row['created_at'] && to_time(row['created_at']),
            updated_at: row['updated_at'] && to_time(row['updated_at'])
          )
        end

        def load_metadata_sql
          "#{joined_columns_sql} ORDER BY em.table_name, em.column_name"
        end

        def column_config_sql
          "#{joined_columns_sql} WHERE em.table_name = ? AND em.column_name = ?"
        end

        def table_configs_sql
          "#{joined_columns_sql} WHERE em.table_name = ?"
        end

        def check_column_encrypted_sql
          "SELECT 1 FROM #{@config.metadata_schema}.encryption_metadata " \
            'WHERE table_name = ? AND column_name = ?'
        end

        # +ks.key_id+ is aliased because +em.key_id+ already occupies that name in the row: the
        # metadata table's key_id is the integer foreign key into key_storage.id, while the key
        # storage table's own key_id is the external identifier of the key.
        #
        # The join is an outer one so that a column whose key row is missing is still reported as
        # configured for kms_encryption. An inner join would drop it, the column would look like an
        # ordinary one, and a write would store the plaintext. Kept this way, its key metadata comes
        # back empty, which fails validation and so fails the write instead.
        def joined_columns_sql
          schema = @config.metadata_schema
          'SELECT em.table_name, em.column_name, em.encryption_algorithm, em.key_id, ' \
            'em.created_at, em.updated_at, ' \
            'ks.key_id AS key_uuid, ks.name, ks.master_key_arn, ks.encrypted_data_key, ks.hmac_key, ks.key_spec, ' \
            'ks.created_at AS key_created_at, ks.last_used_at ' \
            "FROM #{schema}.encryption_metadata em " \
            "LEFT JOIN #{schema}.key_storage ks ON em.key_id = ks.id"
        end

        def start_refresh_thread
          @running = true
          interval = @config.metadata_cache_refresh_interval_sec

          thread = Thread.new do
            while @running
              sleep(interval)
              break unless @running

              begin
                refresh
              rescue StandardError => e
                logger.warn("Failed to refresh the kms_encryption metadata cache: #{e.message}")
              end
            end
          end
          thread.name = 'kms_encryption-metadata-refresh'
          @refresh_thread = thread
          logger.debug { "Started the kms_encryption metadata refresh thread with a #{interval}s interval" }
        end
      end
    end
  end
end
