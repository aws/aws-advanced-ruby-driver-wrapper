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

require_relative '../../property_definition'
require_relative 'schema_name'

module AwsRubyDatabaseDriverWrapper
  module Plugins
    module Encryption
      # The plugin's own configuration, resolved once from the wrapper properties.
      #
      # Every duration is in seconds, matching the rest of the wrapper, except for
      # +retry_backoff_base_ms+ whose property name says milliseconds.
      EncryptionConfig = Data.define(
        :kms_region,
        :kms_endpoint,
        :metadata_schema,
        :metadata_cache_enabled,
        :metadata_cache_expiration_sec,
        :metadata_cache_refresh_interval_sec,
        :key_management_max_retries,
        :key_management_retry_backoff_base_ms,
        :audit_logging_enabled,
        :data_key_cache_enabled,
        :data_key_cache_max_size,
        :data_key_cache_expiration_sec
      )

      class EncryptionConfig
        DEFAULT_REGION = 'us-east-1'

        class << self
          # Builds the configuration from the wrapper properties, applying defaults and
          # validating the result.
          #
          # @param props [Concurrent::Map, Hash] the wrapper properties
          # @return [EncryptionConfig]
          # @raise [ArgumentError] if a value is out of range
          def from_props(props)
            new(
              kms_region: PropertyDefinition::ENCRYPTION_KMS_REGION.get_string(props) || default_region,
              kms_endpoint: PropertyDefinition::ENCRYPTION_KMS_ENDPOINT.get_string(props),
              metadata_schema: SchemaName.of(PropertyDefinition::ENCRYPTION_METADATA_SCHEMA.get_string(props)),
              metadata_cache_enabled: PropertyDefinition::ENCRYPTION_METADATA_CACHE_ENABLED.get_bool(props),
              metadata_cache_expiration_sec: PropertyDefinition::ENCRYPTION_METADATA_CACHE_EXPIRATION_SEC.get_int(props),
              metadata_cache_refresh_interval_sec:
                PropertyDefinition::ENCRYPTION_METADATA_CACHE_REFRESH_INTERVAL_SEC.get_int(props),
              key_management_max_retries: PropertyDefinition::ENCRYPTION_KEY_MANAGEMENT_MAX_RETRIES.get_int(props),
              key_management_retry_backoff_base_ms:
                PropertyDefinition::ENCRYPTION_KEY_MANAGEMENT_RETRY_BACKOFF_BASE_MS.get_int(props),
              audit_logging_enabled: PropertyDefinition::ENCRYPTION_AUDIT_LOGGING_ENABLED.get_bool(props),
              data_key_cache_enabled: PropertyDefinition::ENCRYPTION_DATA_KEY_CACHE_ENABLED.get_bool(props),
              data_key_cache_max_size: PropertyDefinition::ENCRYPTION_DATA_KEY_CACHE_MAX_SIZE.get_int(props),
              data_key_cache_expiration_sec: PropertyDefinition::ENCRYPTION_DATA_KEY_CACHE_EXPIRATION_SEC.get_int(props)
            )
          end

          private

          def default_region
            ENV['AWS_REGION'] || ENV['AWS_DEFAULT_REGION'] || DEFAULT_REGION
          end
        end

        # Every setting the plugin reads is one keyword, so that the defaults live here rather than
        # in each caller.
        # rubocop:disable Metrics/ParameterLists
        def initialize(kms_region:, metadata_schema:, kms_endpoint: nil, metadata_cache_enabled: true,
                       metadata_cache_expiration_sec: 3600, metadata_cache_refresh_interval_sec: 300,
                       key_management_max_retries: 3, key_management_retry_backoff_base_ms: 100,
                       audit_logging_enabled: false, data_key_cache_enabled: true,
                       data_key_cache_max_size: 1000, data_key_cache_expiration_sec: 3600)
          super(
            kms_region: kms_region,
            kms_endpoint: kms_endpoint,
            metadata_schema: SchemaName.of(metadata_schema),
            metadata_cache_enabled: metadata_cache_enabled,
            metadata_cache_expiration_sec: metadata_cache_expiration_sec,
            metadata_cache_refresh_interval_sec: metadata_cache_refresh_interval_sec,
            key_management_max_retries: key_management_max_retries,
            key_management_retry_backoff_base_ms: key_management_retry_backoff_base_ms,
            audit_logging_enabled: audit_logging_enabled,
            data_key_cache_enabled: data_key_cache_enabled,
            data_key_cache_max_size: data_key_cache_max_size,
            data_key_cache_expiration_sec: data_key_cache_expiration_sec
          )
          validate!
        end
        # rubocop:enable Metrics/ParameterLists

        # @return [Boolean] true when the metadata should be refreshed on a background thread
        def background_refresh_enabled?
          metadata_cache_enabled && metadata_cache_refresh_interval_sec.positive?
        end

        # @return [self]
        # @raise [ArgumentError] if a value is out of range
        def validate!
          raise ArgumentError, 'encryption_kms_region cannot be empty' if kms_region.to_s.strip.empty?

          PropertyDefinition::ENCRYPTION_METADATA_CACHE_EXPIRATION_SEC.validate!(metadata_cache_expiration_sec)
          PropertyDefinition::ENCRYPTION_METADATA_CACHE_REFRESH_INTERVAL_SEC.validate!(metadata_cache_refresh_interval_sec)
          PropertyDefinition::ENCRYPTION_KEY_MANAGEMENT_MAX_RETRIES.validate!(key_management_max_retries)
          PropertyDefinition::ENCRYPTION_KEY_MANAGEMENT_RETRY_BACKOFF_BASE_MS.validate!(key_management_retry_backoff_base_ms)
          PropertyDefinition::ENCRYPTION_DATA_KEY_CACHE_MAX_SIZE.validate!(data_key_cache_max_size)
          PropertyDefinition::ENCRYPTION_DATA_KEY_CACHE_EXPIRATION_SEC.validate!(data_key_cache_expiration_sec)
          self
        end
      end
    end
  end
end
