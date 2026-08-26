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

require_relative 'sanitizer'

module AwsRubyDatabaseDriverWrapper
  module Plugins
    module Encryption
      # One row of the +key_storage+ table: an encrypted data key, the master key that wraps
      # it, and the HMAC key used to sign the payloads it encrypts.
      #
      # The data key is only ever held here in its encrypted form. The plaintext key exists
      # only for the duration of a single encrypt or decrypt call and is zeroed afterward.
      KeyMetadata = Data.define(
        :id,
        :key_id,
        :key_name,
        :master_key_arn,
        :encrypted_data_key,
        :hmac_key,
        :key_spec,
        :created_at,
        :last_used_at
      )

      class KeyMetadata
        DEFAULT_KEY_SPEC = 'AES_256'

        # @param id [Integer, nil] the +key_storage.id+ surrogate key, nil before the row is inserted
        # @param key_id [String, nil] the +key_storage.key_id+ identifier
        # @param key_name [String, nil] a human-readable name for the key
        # @param master_key_arn [String, nil] the ARN of the KMS master key wrapping the data key
        # @param encrypted_data_key [String, nil] the base64 encoded, KMS encrypted data key
        # @param hmac_key [String, nil] the binary HMAC-SHA256 key used for integrity protection
        # @param key_spec [String] the KMS data key spec, e.g. 'AES_256'
        # @param created_at [Time, nil]
        # @param last_used_at [Time, nil]
        def initialize(id: nil, key_id: nil, key_name: nil, master_key_arn: nil, encrypted_data_key: nil,
                       hmac_key: nil, key_spec: DEFAULT_KEY_SPEC, created_at: nil, last_used_at: nil)
          super
        end

        # @param now [Time]
        # @return [KeyMetadata] a copy stamped with a new last used time
        def with_updated_last_used(now = Time.now)
          with(last_used_at: now)
        end

        # A key is usable once it names a master key, carries an encrypted data key, and states the
        # key spec it was generated under.
        # @return [Boolean]
        def valid?
          !blank?(master_key_arn) && !blank?(encrypted_data_key) && !blank?(key_spec)
        end

        # @return [String] a description with the key material redacted
        def to_s
          "KeyMetadata{id=#{id.inspect}, key_id=#{key_id.inspect}, key_name=#{key_name.inspect}, " \
            "master_key_arn=#{Sanitizer.arn(master_key_arn).inspect}, encrypted_data_key='[REDACTED]', " \
            "hmac_key=#{hmac_key.nil? ? 'nil' : "'[REDACTED]'"}, key_spec=#{key_spec.inspect}, " \
            "created_at=#{created_at.inspect}, last_used_at=#{last_used_at.inspect}}"
        end
        alias inspect to_s

        private

        def blank?(value)
          value.nil? || value.to_s.strip.empty?
        end
      end
    end
  end
end
