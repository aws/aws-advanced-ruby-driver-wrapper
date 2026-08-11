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

require_relative 'errors'

module AwsRubyDatabaseDriverWrapper
  module Plugins
    module Encryption
      # The symmetric algorithms the plugin can use to encrypt column values. The names are
      # the ones stored in the +encryption_metadata.encryption_algorithm+ column and are
      # shared with the other AWS Advanced Wrappers.
      module EncryptionAlgorithm
        AES_256_GCM = 'AES-256-GCM'
        AES_128_GCM = 'AES-128-GCM'
        DEFAULT = AES_256_GCM

        # Expected data key length in bytes for each algorithm.
        KEY_LENGTHS = {
          AES_256_GCM => 32,
          AES_128_GCM => 16
        }.freeze

        # OpenSSL cipher names for each algorithm.
        CIPHERS = {
          AES_256_GCM => 'aes-256-gcm',
          AES_128_GCM => 'aes-128-gcm'
        }.freeze

        ALL = KEY_LENGTHS.keys.freeze

        module_function

        # @param name [String] an algorithm name, e.g. 'AES-256-GCM'
        # @return [Integer] the required data key length in bytes
        # @raise [Errors::EncryptionError] if the algorithm is not supported
        def key_length(name)
          KEY_LENGTHS.fetch(name) { raise unsupported(name) }
        end

        # @param name [String] an algorithm name, e.g. 'AES-256-GCM'
        # @return [String] the OpenSSL cipher name
        # @raise [Errors::EncryptionError] if the algorithm is not supported
        def cipher_name(name)
          CIPHERS.fetch(name) { raise unsupported(name) }
        end

        # @param name [String, nil]
        # @return [Boolean]
        def supported?(name)
          KEY_LENGTHS.key?(name)
        end

        # @param name [String, nil]
        # @return [Errors::EncryptionError]
        def unsupported(name)
          Errors::EncryptionError
            .invalid_algorithm("Unsupported encryption algorithm: #{name.inspect}. Supported algorithms: #{ALL.join(', ')}")
            .with_algorithm(name)
        end
      end
    end
  end
end
