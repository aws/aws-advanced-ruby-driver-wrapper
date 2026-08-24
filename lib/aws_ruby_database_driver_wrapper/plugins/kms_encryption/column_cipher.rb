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

require_relative 'encryption_service'
require_relative 'errors'

module AwsRubyDatabaseDriverWrapper
  module Plugins
    module Encryption
      # Encrypts and decrypts single column values for the duration of one call.
      #
      # A cipher is created for each intercepted call and {#release}d when the call returns. That
      # scope is what keeps plaintext data keys short lived: a key is decrypted at most once per
      # column per call, however many values that call touches, and every copy is zeroed again on
      # release.
      #
      # Values are returned as strings, matching what both drivers hand back for a text column.
      class ColumnCipher
        # @param key_manager [KeyManager]
        # @param sql_runner [SqlRunner] used to read a bytea or blob column into binary data
        def initialize(key_manager:, sql_runner:)
          @key_manager = key_manager
          @sql = sql_runner
          @data_keys = {}
        end

        # Encrypts one value for the column the configuration describes.
        #
        # @param value [Object, nil] the plaintext value
        # @param config [ColumnEncryptionConfig] the column's kms_encryption configuration
        # @return [String, nil] the binary payload to store, nil when value is nil
        # @raise [Errors::EncryptionError] if the value cannot be encrypted
        def encrypt(value, config)
          return nil if value.nil?

          EncryptionService.encrypt(value, data_key_for(config), hmac_key_for(config), config.algorithm)
        end

        # Decrypts one value read from the column the configuration describes.
        #
        # A value that does not carry a valid integrity tag is returned untouched, so that a column
        # holding values written before kms_encryption was turned on still reads back as it was
        # written.
        #
        # @param raw [Object, nil] the raw column value
        # @param config [ColumnEncryptionConfig] the column's kms_encryption configuration
        # @return [Object, nil] the decrypted value, or +raw+ when it is not an encrypted payload
        # @raise [Errors::EncryptionError] if the value is encrypted but cannot be decrypted
        def decrypt(raw, config)
          return raw unless raw.is_a?(String)

          bytes = @sql.read_binary(raw)
          hmac_key = hmac_key_for(config)
          return raw unless EncryptionService.encrypted_data_valid?(bytes, hmac_key)

          EncryptionService.decrypt(bytes, data_key_for(config), hmac_key, config.algorithm, target_type: String)
        end

        # @param raw [Object, nil] a raw column value
        # @return [Boolean] whether the value even looks like an encrypted payload
        def encrypted_payload?(raw)
          raw.is_a?(String) && @sql.read_binary(raw).bytesize >= EncryptionService::MIN_ENCRYPTED_LENGTH
        end

        # Zeroes every plaintext data key this cipher decrypted.
        # @return [void]
        def release
          @data_keys.each_value { |data_key| EncryptionService.wipe(data_key) }
          @data_keys.clear
          nil
        end

        private

        def data_key_for(config)
          metadata = key_metadata!(config)
          @data_keys[metadata.encrypted_data_key] ||=
            @key_manager.decrypt_data_key(metadata.encrypted_data_key, metadata.master_key_arn)
        end

        def hmac_key_for(config)
          hmac_key = key_metadata!(config).hmac_key
          if hmac_key.nil? || hmac_key.empty?
            raise Errors::EncryptionError
              .invalid_key('The stored key has no HMAC key')
              .with_table(config.table_name)
              .with_column(config.column_name)
          end

          hmac_key
        end

        def key_metadata!(config)
          metadata = config.key_metadata
          if metadata.nil?
            raise Errors::EncryptionError
              .invalid_key('The column has no key material')
              .with_table(config.table_name)
              .with_column(config.column_name)
          end

          metadata
        end
      end
    end
  end
end
