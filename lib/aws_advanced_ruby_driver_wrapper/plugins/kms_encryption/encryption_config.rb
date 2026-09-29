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

module AwsAdvancedRubyDriverWrapper
  module Plugins
    module Encryption
      # The plugin's own configuration, resolved once from the wrapper properties.
      EncryptionConfig = Data.define(
        :kms_region,
        :kms_endpoint,
        :allowed_master_key_arns,
        :metadata_schema,
        :metadata_cache_enabled,
        :metadata_cache_expiration_sec,
        :metadata_cache_refresh_interval_sec,
        :key_management_max_retries,
        :key_management_retry_backoff_base_sec,
        :audit_logging_enabled,
        :data_key_cache_enabled,
        :data_key_cache_max_size,
        :data_key_cache_expiration_sec,
        :return_unverified_data
      )

      class EncryptionConfig
        class << self
          # Builds the configuration from the wrapper properties, applying defaults and
          # validating the result.
          #
          # @param props [Concurrent::Map, Hash] the wrapper properties
          # @return [EncryptionConfig]
          # @raise [ArgumentError] if a value is out of range, or if no region was configured
          def from_props(props)
            new(
              kms_region: PropertyDefinition::ENCRYPTION_KMS_REGION.get_string(props) || region_from_env,
              kms_endpoint: PropertyDefinition::ENCRYPTION_KMS_ENDPOINT.get_string(props),
              allowed_master_key_arns: PropertyDefinition::ENCRYPTION_ALLOWED_MASTER_KEY_ARNS.get(props),
              metadata_schema: SchemaName.of(PropertyDefinition::ENCRYPTION_METADATA_SCHEMA.get_string(props)),
              metadata_cache_enabled: PropertyDefinition::ENCRYPTION_METADATA_CACHE_ENABLED.get_bool(props),
              metadata_cache_expiration_sec: PropertyDefinition::ENCRYPTION_METADATA_CACHE_EXPIRATION_SEC.get_float(props),
              metadata_cache_refresh_interval_sec:
                PropertyDefinition::ENCRYPTION_METADATA_CACHE_REFRESH_INTERVAL_SEC.get_float(props),
              key_management_max_retries: PropertyDefinition::ENCRYPTION_KEY_MANAGEMENT_MAX_RETRIES.get_int(props),
              key_management_retry_backoff_base_sec:
                PropertyDefinition::ENCRYPTION_KEY_MANAGEMENT_RETRY_BACKOFF_BASE_SEC.get_float(props),
              audit_logging_enabled: PropertyDefinition::ENCRYPTION_AUDIT_LOGGING_ENABLED.get_bool(props),
              data_key_cache_enabled: PropertyDefinition::ENCRYPTION_DATA_KEY_CACHE_ENABLED.get_bool(props),
              data_key_cache_max_size: PropertyDefinition::ENCRYPTION_DATA_KEY_CACHE_MAX_SIZE.get_int(props),
              data_key_cache_expiration_sec: PropertyDefinition::ENCRYPTION_DATA_KEY_CACHE_EXPIRATION_SEC.get_float(props),
              return_unverified_data: PropertyDefinition::ENCRYPTION_RETURN_UNVERIFIED_DATA.get_bool(props)
            )
          end

          private

          def region_from_env
            ENV.fetch('AWS_REGION', nil) || ENV.fetch('AWS_DEFAULT_REGION', nil)
          end
        end

        def initialize(kms_region:, kms_endpoint:, metadata_schema:, metadata_cache_enabled:,
                       metadata_cache_expiration_sec:, metadata_cache_refresh_interval_sec:,
                       key_management_max_retries:, key_management_retry_backoff_base_sec:,
                       audit_logging_enabled:, data_key_cache_enabled:,
                       data_key_cache_max_size:, data_key_cache_expiration_sec:, return_unverified_data:,
                       allowed_master_key_arns: [])
          super(
            kms_region: kms_region,
            kms_endpoint: kms_endpoint,
            allowed_master_key_arns: normalize_arns(allowed_master_key_arns),
            metadata_schema: SchemaName.of(metadata_schema),
            metadata_cache_enabled: metadata_cache_enabled,
            metadata_cache_expiration_sec: metadata_cache_expiration_sec,
            metadata_cache_refresh_interval_sec: metadata_cache_refresh_interval_sec,
            key_management_max_retries: key_management_max_retries,
            key_management_retry_backoff_base_sec: key_management_retry_backoff_base_sec,
            audit_logging_enabled: audit_logging_enabled,
            data_key_cache_enabled: data_key_cache_enabled,
            data_key_cache_max_size: data_key_cache_max_size,
            data_key_cache_expiration_sec: data_key_cache_expiration_sec,
            return_unverified_data: return_unverified_data
          )
          validate!
        end

        # @return [Boolean] true when the metadata should be refreshed on a background thread
        def background_refresh_enabled?
          metadata_cache_enabled && metadata_cache_refresh_interval_sec.positive?
        end

        # An empty allow-list (the default) places no restriction on the master keys used - acceptable
        # for the administrative utility, but refused by the plugin itself (see {KmsEncryptionUtility}).
        #
        # @return [Boolean] true when only the listed master keys may be used
        def restricts_master_keys?
          !allowed_master_key_arns.empty?
        end

        # @param master_key_arn [String, nil] a master key ARN, as recorded in +key_storage+
        # @return [Boolean] true when no restriction is configured, or the key is on the allow-list
        def master_key_allowed?(master_key_arn)
          !restricts_master_keys? || allowed_master_key_arns.include?(master_key_arn)
        end

        # @return [self]
        # @raise [ArgumentError] if a value is out of range
        def validate!
          raise ArgumentError, 'encryption_kms_region cannot be empty' if kms_region.to_s.strip.empty?

          PropertyDefinition::ENCRYPTION_METADATA_CACHE_EXPIRATION_SEC.validate!(metadata_cache_expiration_sec)
          PropertyDefinition::ENCRYPTION_METADATA_CACHE_REFRESH_INTERVAL_SEC.validate!(metadata_cache_refresh_interval_sec)
          PropertyDefinition::ENCRYPTION_KEY_MANAGEMENT_MAX_RETRIES.validate!(key_management_max_retries)
          PropertyDefinition::ENCRYPTION_KEY_MANAGEMENT_RETRY_BACKOFF_BASE_SEC.validate!(key_management_retry_backoff_base_sec)
          PropertyDefinition::ENCRYPTION_DATA_KEY_CACHE_MAX_SIZE.validate!(data_key_cache_max_size)
          PropertyDefinition::ENCRYPTION_DATA_KEY_CACHE_EXPIRATION_SEC.validate!(data_key_cache_expiration_sec)
          self
        end

        private

        # Accepts nil, an array, or a comma-separated string, and returns a frozen array of the unique,
        # non-blank entries.
        def normalize_arns(value)
          entries = value.is_a?(String) ? value.split(',') : Array(value)
          entries.map { |arn| arn.to_s.strip }.reject(&:empty?).uniq.freeze
        end
      end
    end
  end
end
