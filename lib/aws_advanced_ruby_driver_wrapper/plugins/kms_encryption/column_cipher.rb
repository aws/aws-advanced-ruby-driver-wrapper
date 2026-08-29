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

module AwsAdvancedRubyDriverWrapper
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
          # Key material resolved by the id embedded in a value, cached for the cipher's lifetime so
          # a result full of rows written under a rotated-away key costs one lookup, not one per row.
          @key_metadata_by_id = {}
        end

        # Encrypts one value for the column the configuration describes.
        #
        # @param value [Object, nil] the plaintext value
        # @param config [ColumnEncryptionConfig] the column's kms_encryption configuration
        # @return [String, nil] the binary payload to store, nil when value is nil
        # @raise [Errors::EncryptionError] if the value cannot be encrypted
        def encrypt(value, config)
          return nil if value.nil?

          metadata = key_metadata!(config)
          EncryptionService.encrypt(
            value, data_key_for(metadata), hmac_key_for(metadata, config), config.algorithm, key_id: metadata.id
          )
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

          # A column configured for kms_encryption must have key material; its absence is a
          # misconfiguration worth failing on, as on the encrypt side.
          key_metadata!(config)

          bytes = @sql.read_binary(raw)
          # Resolve the key the value was written with from the id in its payload, so a value written
          # before a key rotation still decrypts. A value with no resolvable key (legacy data, or a
          # key no longer in key_storage) falls back to the current key, fails the integrity check
          # below, and is returned untouched.
          metadata = key_metadata_for_value(bytes, config)
          hmac_key = metadata&.hmac_key
          return raw if hmac_key.nil? || hmac_key.empty?
          return raw unless EncryptionService.encrypted_data_valid?(bytes, hmac_key)

          EncryptionService.decrypt(bytes, data_key_for(metadata), hmac_key, config.algorithm, target_type: String)
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

        # The key a stored value was written with. The payload records the +key_storage+ id, so a
        # value keeps decrypting after its column's key has been rotated: the current key is used
        # when the ids match (the common case, and the only one that needs no extra lookup), and any
        # other id is fetched from +key_storage+ and cached. A value with no embedded id (legacy
        # data) or one whose key is gone falls back to the current key, which then fails the
        # integrity check and is returned untouched by {#decrypt}.
        #
        # @return [KeyMetadata, nil]
        def key_metadata_for_value(bytes, config)
          current = config.key_metadata
          key_id = EncryptionService.key_id_from_payload(bytes)
          return current if key_id.nil? || (current && current.id == key_id)

          @key_metadata_by_id[key_id] ||= resolve_key_metadata(key_id) || current
        end

        # Looks a key up by the id embedded in a value. The read is lenient, so this is opportunistic:
        # a value that is not really an encrypted payload (legacy data, tampered bytes) can carry an
        # arbitrary id, and a value written before this format carries none, so a lookup that finds
        # nothing or fails must not surface as an error - the caller falls back to the current key and
        # the value fails its integrity check and is returned untouched.
        def resolve_key_metadata(key_id)
          @key_manager.key_metadata_by_id(key_id)
        rescue Errors::EncryptionPluginError
          nil
        end

        def data_key_for(metadata)
          @data_keys[metadata.encrypted_data_key] ||=
            @key_manager.decrypt_data_key(metadata.encrypted_data_key, metadata.master_key_arn)
        end

        def hmac_key_for(metadata, config)
          hmac_key = metadata.hmac_key
          return hmac_key unless hmac_key.nil? || hmac_key.empty?

          raise Errors::EncryptionError
            .invalid_key('The stored key has no HMAC key')
            .with_table(config.table_name)
            .with_column(config.column_name)
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
