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

require_relative 'encryption_algorithm'
require_relative 'key_metadata'

module AwsRubyDatabaseDriverWrapper
  module Plugins
    module Encryption
      # One row of the +encryption_metadata+ table joined with the key it points at: the
      # algorithm to use for a single table column, and the key material to use with it.
      ColumnEncryptionConfig = Data.define(
        :table_name,
        :column_name,
        :algorithm,
        :key_id,
        :key_metadata,
        :created_at,
        :updated_at
      )

      class ColumnEncryptionConfig
        # @param table_name [String]
        # @param column_name [String]
        # @param algorithm [String] an {EncryptionAlgorithm} name
        # @param key_id [Integer, nil] the +encryption_metadata.key_id+ foreign key
        # @param key_metadata [KeyMetadata, nil] the joined +key_storage+ row
        # @param created_at [Time, nil]
        # @param updated_at [Time, nil]
        def initialize(table_name:, column_name:, algorithm: EncryptionAlgorithm::DEFAULT, key_id: nil,
                       key_metadata: nil, created_at: nil, updated_at: nil)
          super
        end

        # The cache key for this column, e.g. 'users.ssn'.
        # @return [String]
        def column_identifier
          "#{table_name}.#{column_name}"
        end

        # @return [Boolean] true when the column has key material and a supported algorithm
        def usable?
          EncryptionAlgorithm.supported?(algorithm) && !key_metadata.nil? && key_metadata.valid?
        end
      end
    end
  end
end
