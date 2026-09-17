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

require 'base64'
require 'digest'
require 'securerandom'
require_relative '../../logging'
require_relative '../../utils/conversion_utils'
require_relative 'connection_source'
require_relative 'errors'
require_relative 'key_metadata'

module AwsAdvancedRubyDriverWrapper
  module Plugins
    module Encryption
      # Owns the data keys: generates them through KMS, stores them in +key_storage+, and
      # decrypts them again on the way back, caching the plaintext keys in memory.
      #
      # Plaintext data keys never reach the database. Only the KMS encrypted form is stored,
      # and the plaintext copies handed out here are zeroed by their callers once used.
      class KeyManager
        include Logging
        include Utils::ConversionUtils
        include ConnectionSource

        DATA_KEY_CACHE_PREFIX = 'datakey_'
        HMAC_KEY_LENGTH = 32
        KMS_KEY_SPEC = 'AES_256'
        KMS_MASTER_KEY_SPEC = 'SYMMETRIC_DEFAULT'
        KMS_KEY_USAGE = 'ENCRYPT_DECRYPT'
        JITTER_RATIO = 0.25
        MAX_BACKOFF_SEC = 20.0

        # KMS error codes that are worth retrying.
        RETRYABLE_ERROR_CODES = %w[
          ThrottlingException
          LimitExceededException
          KMSInternalException
          KeyUnavailableException
          DependencyTimeoutException
          RequestTimeout
          ServiceUnavailable
          InternalFailure
        ].freeze

        # A freshly generated data key, in both its plaintext and stored forms.
        GeneratedDataKey = Data.define(:plaintext, :encrypted_data_key, :hmac_key)

        # Exactly one of +connection+ or +service_container+ must be given (see {ConnectionSource}).
        #
        # @param kms_client [Aws::KMS::Client]
        # @param sql_runner [SqlRunner]
        # @param config [EncryptionConfig]
        # @param data_key_cache [DataKeyCache]
        # @param connection [Object, nil] a caller-owned connection used for every operation
        # @param service_container [Services::ServiceContainer, nil] opens a short-lived connection per operation
        # @param audit_logger [AuditLogger, nil]
        def initialize(kms_client:, sql_runner:, config:, data_key_cache:, connection: nil, service_container: nil,
                       audit_logger: nil)
          @kms_client = kms_client
          use_connection_source(connection: connection, service_container: service_container)
          @sql = sql_runner
          @config = config
          @cache = data_key_cache
          @audit_logger = audit_logger
          @schema = config.metadata_schema
        end

        # Decrypts a stored data key, using the in-memory cache when possible.
        #
        # @param encrypted_data_key [String] the base64 encoded, KMS encrypted data key
        # @param master_key_arn [String, nil] the ARN of the master key, for audit records
        # @return [String] the plaintext data key; the caller should wipe it once used
        # @raise [Errors::KeyManagementError] if KMS rejects the request
        def decrypt_data_key(encrypted_data_key, master_key_arn = nil)
          if encrypted_data_key.nil? || encrypted_data_key.to_s.strip.empty?
            raise Errors::KeyManagementError
              .invalid_key_metadata('The stored key metadata has no encrypted data key')
              .with_master_key_arn(master_key_arn)
          end

          cache_key = data_key_cache_key(encrypted_data_key)
          cached = @cache.get(cache_key)
          return cached if cached

          plaintext = with_retry('DECRYPT_DATA_KEY') do
            response = @kms_client.decrypt(
              ciphertext_blob: Base64.strict_decode64(encrypted_data_key.to_s.delete("\n")),
              **(master_key_arn ? { key_id: master_key_arn } : {})
            )
            response.plaintext.dup.b
          end

          @cache.put(cache_key, plaintext)
          @audit_logger&.log_data_key_decryption(master_key_arn: master_key_arn, success: true)
          plaintext
        rescue Errors::KeyManagementError => e
          @audit_logger&.log_data_key_decryption(master_key_arn: master_key_arn, success: false, error_message: e.message)
          raise
        end

        # Asks KMS for a new data key and generates the HMAC key that goes with it.
        #
        # @param master_key_arn [String] the ARN of the master key to wrap the data key with
        # @return [GeneratedDataKey]
        # @raise [Errors::KeyManagementError] if KMS rejects the request
        def generate_data_key(master_key_arn)
          result = with_retry('GENERATE_DATA_KEY') do
            response = @kms_client.generate_data_key(key_id: master_key_arn, key_spec: KMS_KEY_SPEC)
            GeneratedDataKey.new(
              plaintext: response.plaintext.dup.b,
              encrypted_data_key: Base64.strict_encode64(response.ciphertext_blob),
              hmac_key: SecureRandom.bytes(HMAC_KEY_LENGTH)
            )
          end

          @audit_logger&.log_data_key_generation(master_key_arn: master_key_arn, success: true)
          result
        rescue Errors::KeyManagementError => e
          @audit_logger&.log_data_key_generation(master_key_arn: master_key_arn, success: false, error_message: e.message)
          raise
        end

        # Creates a new KMS master key.
        #
        # @param description [String] the key description
        # @return [String] the ARN of the new key
        # @raise [Errors::KeyManagementError] if KMS rejects the request
        def create_master_key(description)
          arn = with_retry('CREATE_MASTER_KEY') do
            response = @kms_client.create_key(
              description: description,
              key_usage: KMS_KEY_USAGE,
              key_spec: KMS_MASTER_KEY_SPEC
            )
            response.key_metadata.arn
          end

          @audit_logger&.log_key_creation(master_key_arn: arn, description: description, success: true)
          arn
        rescue Errors::KeyManagementError => e
          @audit_logger&.log_key_creation(master_key_arn: nil, description: description, success: false, error_message: e.message)
          raise
        end

        # Checks that a master key exists, is enabled, and can encrypt and decrypt.
        #
        # @param master_key_arn [String]
        # @return [Boolean]
        def validate_master_key(master_key_arn)
          metadata = with_retry('DESCRIBE_MASTER_KEY') { @kms_client.describe_key(key_id: master_key_arn).key_metadata }
          metadata.enabled && metadata.key_state == 'Enabled' && metadata.key_usage == KMS_KEY_USAGE
        rescue Errors::KeyManagementError => e
          logger.warn("Master key validation failed: #{e.message}")
          false
        end

        # Inserts a row into +key_storage+.
        #
        # @param key_metadata [KeyMetadata] the key to store; its +id+ is ignored
        # @return [KeyMetadata] the stored key, with +id+ and timestamps filled in
        # @raise [Errors::KeyManagementError] if the row cannot be written
        def store_key_metadata(key_metadata)
          unless key_metadata.valid?
            raise Errors::KeyManagementError.invalid_key_metadata(
              'Refusing to store key metadata that names no master key or carries no encrypted data key'
            )
          end

          now = Time.now
          to_store = key_metadata.with(
            key_id: key_metadata.key_id || generate_key_id,
            created_at: key_metadata.created_at || now,
            last_used_at: key_metadata.last_used_at || now
          )

          id = with_connection(operation: 'STORE_KEY_METADATA') do |connection|
            @sql.insert_returning_id(connection, insert_key_sql, [
                                       to_store.key_id,
                                       to_store.key_name,
                                       to_store.master_key_arn,
                                       to_store.encrypted_data_key,
                                       @sql.binary_param(to_store.hmac_key),
                                       to_store.key_spec,
                                       to_store.created_at,
                                       to_store.last_used_at
                                     ])
          end

          to_store.with(id: id)
        rescue StandardError => e
          raise wrap_storage_error(e, to_store&.key_id)
        end

        # Reads one row of +key_storage+ by its surrogate id.
        #
        # @param id [Integer] the +key_storage.id+ value
        # @return [KeyMetadata, nil]
        # @raise [Errors::KeyManagementError] if the row cannot be read
        def key_metadata_by_id(id)
          row = with_connection(operation: 'GET_KEY_METADATA') do |connection|
            @sql.query(connection, select_key_sql, [id]).first
          end
          row && to_key_metadata(row)
        rescue StandardError => e
          raise Errors::KeyManagementError
            .key_retrieval_failed("Failed to read key metadata: #{e.message}")
            .with_key_id(id.to_s)
        end

        # Stamps a key as used. Failures are logged and swallowed: this is bookkeeping only.
        #
        # @param key_id [String] the +key_storage.key_id+ value
        # @return [void]
        def touch_key(key_id)
          with_connection(operation: 'UPDATE_KEY_LAST_USED') do |connection|
            @sql.execute(connection, update_last_used_sql, [Time.now, key_id])
          end
          nil
        rescue StandardError => e
          logger.debug("Failed to update last_used_at for key #{key_id}: #{e.message}")
          nil
        end

        # Builds a {KeyMetadata} from a +key_storage+ row.
        #
        # @param row [Hash{String => Object}]
        # @return [KeyMetadata]
        def to_key_metadata(row)
          KeyMetadata.new(
            id: row['id']&.to_i,
            key_id: row['key_id'],
            key_name: row['name'],
            master_key_arn: row['master_key_arn'],
            encrypted_data_key: row['encrypted_data_key'],
            hmac_key: @sql.read_binary(row['hmac_key']),
            key_spec: row['key_spec'] || KeyMetadata::DEFAULT_KEY_SPEC,
            created_at: row['created_at'] && to_time(row['created_at']),
            last_used_at: row['last_used_at'] && to_time(row['last_used_at'])
          )
        end

        # @return [String] a new identifier for the +key_storage.key_id+ column
        def generate_key_id
          SecureRandom.uuid
        end

        # The cache key for a stored data key. Hashing keeps the encrypted key itself out of
        # the cache keys, which can end up in log messages.
        #
        # @param encrypted_data_key [String]
        # @return [String]
        def data_key_cache_key(encrypted_data_key)
          "#{DATA_KEY_CACHE_PREFIX}#{Base64.strict_encode64(Digest::SHA256.digest(encrypted_data_key.to_s))}"
        end

        private

        def insert_key_sql
          "INSERT INTO #{@schema}.key_storage " \
            '(key_id, name, master_key_arn, encrypted_data_key, hmac_key, key_spec, created_at, last_used_at) ' \
            'VALUES (?, ?, ?, ?, ?, ?, ?, ?)'
        end

        def select_key_sql
          'SELECT id, key_id, name, master_key_arn, encrypted_data_key, hmac_key, key_spec, created_at, last_used_at ' \
            "FROM #{@schema}.key_storage WHERE id = ?"
        end

        def update_last_used_sql
          "UPDATE #{@schema}.key_storage SET last_used_at = ? WHERE key_id = ?"
        end

        # Runs a KMS call, retrying throttling and transient service errors with exponential
        # backoff and jitter.
        def with_retry(operation)
          attempt = 0
          max_retries = @config.key_management_max_retries

          loop do
            return yield
          rescue StandardError => e
            raise kms_error(e, operation, attempt, max_retries) if attempt >= max_retries || !retryable?(e)

            delay = backoff_sec(attempt)
            logger.debug do
              "#{operation} failed (attempt #{attempt + 1}/#{max_retries + 1}), retrying in #{format('%.3f', delay)}s: #{e.message}"
            end
            sleep(delay)
            attempt += 1
          end
        end

        def retryable?(error)
          return true if networking_error?(error)
          return false unless error.respond_to?(:context)

          status = error.context&.http_response&.status_code
          return true if status && (status >= 500 || status == 429)

          RETRYABLE_ERROR_CODES.include?(error.class.name.split('::').last)
        end

        def networking_error?(error)
          (defined?(Seahorse::Client::NetworkingError) && error.is_a?(Seahorse::Client::NetworkingError)) ||
            error.is_a?(Errno::ECONNREFUSED) || error.is_a?(Errno::ETIMEDOUT) || error.is_a?(Timeout::Error) ||
            error.is_a?(SocketError) || error.is_a?(IOError)
        end

        # base * 2**attempt, plus or minus a quarter, at least the base delay.
        def backoff_sec(attempt)
          base_sec = @config.key_management_retry_backoff_base_sec
          exponential = base_sec * (2**attempt)
          jitter = exponential * JITTER_RATIO * ((SecureRandom.random_number * 2) - 1)
          # Not clamp: the configured base delay is allowed to be longer than the cap, and the cap
          # wins when it is.
          delay_sec = [exponential + jitter, base_sec].max
          [delay_sec, MAX_BACKOFF_SEC].min
        end

        def kms_error(error, operation, attempt, max_retries)
          return error if error.is_a?(Errors::KeyManagementError)

          message = "#{operation} failed: #{error.message}"
          error_class = networking_error?(error) ? :kms_connection_failed : :key_decryption_failed
          Errors::KeyManagementError
            .public_send(error_class, message)
            .with_operation(operation)
            .with_retry_info(attempt + 1, max_retries + 1)
        end

        def wrap_storage_error(error, key_id)
          return error if error.is_a?(Errors::KeyManagementError)

          Errors::KeyManagementError
            .key_storage_failed("Failed to store key metadata: #{error.message}")
            .with_key_id(key_id.to_s)
        end
      end
    end
  end
end
