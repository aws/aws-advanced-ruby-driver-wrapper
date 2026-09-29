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

require_relative '../../errors'
require_relative 'sanitizer'

module AwsAdvancedRubyDriverWrapper
  module Errors
    # Base class for every failure raised by the kms_encryption plugin. Carries a stable
    # error code and an ordered context hash that is appended to the message, so that a
    # failure can be traced back to the table, column, key, and operation involved without
    # leaking the encrypted values themselves.
    #
    # Context is populated with fluent +with_*+ helpers, each of which returns self:
    #
    #   raise Errors::EncryptionError.encryption_failed('Cipher rejected the key')
    #                               .with_table('users').with_column('ssn')
    class EncryptionPluginError < AwsError
      Sanitizer = Plugins::Encryption::Sanitizer

      attr_reader :code, :base_message, :context

      # @param message [String] the message without any context appended
      # @param code [String, nil] a stable error code, e.g. 'ENC01'
      # @param context [Hash] initial context entries; nil values are dropped
      def initialize(message, code: nil, context: {})
        super(message)
        @base_message = message.to_s
        @code = code || default_code
        @context = {}
        context.each { |key, value| with_context(key, value) }
      end

      # The error code used when one is not passed explicitly. Subclasses override this; the base
      # class has no default code.
      # @return [String, nil]
      def default_code
        nil
      end

      # Adds a context entry, ignoring nil values so that unknown details are simply absent.
      # @return [self]
      def with_context(key, value)
        @context[key.to_sym] = value unless value.nil?
        self
      end

      # @return [self]
      def with_operation(operation)
        with_context(:operation, operation)
      end

      # The message with the accumulated context appended.
      # @return [String]
      def to_s
        return @base_message if @context.empty?

        "#{@base_message} [Context: #{@context.map { |key, value| "#{key}=#{value}" }.join(', ')}]"
      end
    end

    # Raised when a value cannot be encrypted or decrypted, or when the encrypted payload
    # fails its integrity check.
    class EncryptionError < EncryptionPluginError
      ENCRYPTION_FAILED = 'ENC01'
      DECRYPTION_FAILED = 'ENC02'
      INVALID_ALGORITHM = 'ENC03'
      INVALID_KEY = 'ENC04'
      TYPE_CONVERSION_FAILED = 'ENC05'
      # A value could not be confirmed to be a valid encrypted payload of this column: it is too
      # short to be one, or its HMAC does not verify. Distinct from DECRYPTION_FAILED, which means a
      # confirmed payload that would not decrypt (a wrong data key), so that a lenient read can
      # return an unverifiable value untouched while still failing closed on a real decryption fault.
      INTEGRITY_CHECK_FAILED = 'ENC06'

      def default_code
        ENCRYPTION_FAILED
      end

      class << self
        def encryption_failed(message, context = {})
          new(message, code: ENCRYPTION_FAILED, context: context)
        end

        def decryption_failed(message, context = {})
          new(message, code: DECRYPTION_FAILED, context: context)
        end

        def integrity_check_failed(message, context = {})
          new(message, code: INTEGRITY_CHECK_FAILED, context: context)
        end

        def invalid_algorithm(message, context = {})
          new(message, code: INVALID_ALGORITHM, context: context)
        end

        def invalid_key(message, context = {})
          new(message, code: INVALID_KEY, context: context)
        end

        def type_conversion_failed(message, context = {})
          new(message, code: TYPE_CONVERSION_FAILED, context: context)
        end
      end

      # @return [self]
      def with_table(table_name)
        with_context(:table, Sanitizer.table_name(table_name))
      end

      # @return [self]
      def with_column(column_name)
        with_context(:column, Sanitizer.column_name(column_name))
      end

      # @return [self]
      def with_algorithm(algorithm)
        with_context(:algorithm, algorithm)
      end

      # @return [self]
      def with_data_type(data_type)
        with_context(:data_type, data_type)
      end
    end

    # Raised when a data key or master key cannot be created, retrieved, decrypted, or stored.
    class KeyManagementError < EncryptionPluginError
      KEY_CREATION_FAILED = 'KEY01'
      KEY_RETRIEVAL_FAILED = 'KEY02'
      KEY_DECRYPTION_FAILED = 'KEY03'
      KEY_STORAGE_FAILED = 'KEY04'
      KMS_CONNECTION_FAILED = 'KEY05'
      INVALID_KEY_METADATA = 'KEY06'
      UNAUTHORIZED_MASTER_KEY = 'KEY07'

      def default_code
        KEY_RETRIEVAL_FAILED
      end

      class << self
        def key_creation_failed(message, context = {})
          new(message, code: KEY_CREATION_FAILED, context: context)
        end

        def key_retrieval_failed(message, context = {})
          new(message, code: KEY_RETRIEVAL_FAILED, context: context)
        end

        def key_decryption_failed(message, context = {})
          new(message, code: KEY_DECRYPTION_FAILED, context: context)
        end

        def key_storage_failed(message, context = {})
          new(message, code: KEY_STORAGE_FAILED, context: context)
        end

        def kms_connection_failed(message, context = {})
          new(message, code: KMS_CONNECTION_FAILED, context: context)
        end

        def invalid_key_metadata(message, context = {})
          new(message, code: INVALID_KEY_METADATA, context: context)
        end

        def unauthorized_master_key(message, context = {})
          new(message, code: UNAUTHORIZED_MASTER_KEY, context: context)
        end
      end

      # @return [self]
      def with_key_id(key_id)
        with_context(:key_id, Sanitizer.key_id(key_id))
      end

      # @return [self]
      def with_master_key_arn(master_key_arn)
        with_context(:master_key_arn, Sanitizer.arn(master_key_arn))
      end

      # @param attempt [Integer] the attempt that failed, 1-based
      # @param max_attempts [Integer]
      # @return [self]
      def with_retry_info(attempt, max_attempts)
        with_context(:retry_attempt, "#{attempt}/#{max_attempts}")
      end
    end

    # Raised when the kms_encryption metadata tables cannot be read, refreshed, or validated.
    class MetadataError < EncryptionPluginError
      METADATA_LOAD_FAILED = 'META01'
      METADATA_CACHE_FAILED = 'META02'
      METADATA_REFRESH_FAILED = 'META03'
      METADATA_LOOKUP_FAILED = 'META04'
      METADATA_VALIDATION_FAILED = 'META05'

      def default_code
        METADATA_LOOKUP_FAILED
      end

      class << self
        def load_failed(message, context = {})
          new(message, code: METADATA_LOAD_FAILED, context: context)
        end

        def cache_failed(message, context = {})
          new(message, code: METADATA_CACHE_FAILED, context: context)
        end

        def refresh_failed(message, context = {})
          new(message, code: METADATA_REFRESH_FAILED, context: context)
        end

        def lookup_failed(message, context = {})
          new(message, code: METADATA_LOOKUP_FAILED, context: context)
        end

        def validation_failed(message, context = {})
          new(message, code: METADATA_VALIDATION_FAILED, context: context)
        end
      end

      # @return [self]
      def with_table(table_name)
        with_context(:table, Sanitizer.table_name(table_name))
      end

      # @return [self]
      def with_column(column_name)
        with_context(:column, Sanitizer.column_name(column_name))
      end

      # @param cache_type [String]
      # @param cache_hit [Boolean]
      # @return [self]
      def with_cache_info(cache_type, cache_hit)
        with_context(:cache_type, cache_type).with_context(:cache_hit, cache_hit)
      end

      # @return [self]
      def with_sql(sql)
        with_context(:sql, Sanitizer.sql(sql))
      end
    end
  end
end
