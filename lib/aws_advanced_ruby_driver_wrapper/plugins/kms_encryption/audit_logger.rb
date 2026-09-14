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

require 'time'
require_relative '../../logging'
require_relative 'sanitizer'

module AwsAdvancedRubyDriverWrapper
  module Plugins
    module Encryption
      # Emits one audit record per key management, kms_encryption, decryption, and metadata
      # operation, enabled with the +encryption_audit_logging_enabled+ property.
      #
      # Records are written to the wrapper's logger as a single +AUDIT+ line of +key=value+
      # fields: successful operations at info level, failures at warn level. Key ids, ARNs,
      # identifiers, and error messages are redacted by {Sanitizer} before being written, so
      # the audit trail never contains key material, credentials, or column values.
      class AuditLogger
        include Logging

        AUDIT_PREFIX = 'AUDIT'

        # @param enabled [Boolean] when false every method is a no-op
        def initialize(enabled)
          @enabled = enabled
        end

        # @return [Boolean]
        def enabled?
          @enabled
        end

        # @param master_key_arn [String, nil]
        # @param description [String, nil]
        # @param success [Boolean]
        # @param error_message [String, nil]
        # @return [void]
        def log_key_creation(master_key_arn:, description: nil, success: true, error_message: nil)
          record('KEY_CREATION', success, error_message,
                 master_key_arn: Sanitizer.arn(master_key_arn),
                 description: Sanitizer.description(description))
        end

        # @return [void]
        def log_data_key_generation(master_key_arn:, key_id: nil, success: true, error_message: nil)
          record('DATA_KEY_GENERATION', success, error_message,
                 master_key_arn: Sanitizer.arn(master_key_arn),
                 key_id: Sanitizer.key_id(key_id))
        end

        # @return [void]
        def log_data_key_decryption(master_key_arn:, key_id: nil, success: true, error_message: nil)
          record('DATA_KEY_DECRYPTION', success, error_message,
                 master_key_arn: Sanitizer.arn(master_key_arn),
                 key_id: Sanitizer.key_id(key_id))
        end

        # @return [void]
        def log_encryption(table_name:, column_name:, key_id: nil, success: true, error_message: nil)
          record('ENCRYPTION', success, error_message,
                 table: Sanitizer.table_name(table_name),
                 column: Sanitizer.column_name(column_name),
                 key_id: Sanitizer.key_id(key_id))
        end

        # @return [void]
        def log_decryption(table_name:, column_name:, key_id: nil, success: true, error_message: nil)
          record('DECRYPTION', success, error_message,
                 table: Sanitizer.table_name(table_name),
                 column: Sanitizer.column_name(column_name),
                 key_id: Sanitizer.key_id(key_id))
        end

        # @param operation [String] the metadata operation, e.g. 'load' or 'refresh'
        # @return [void]
        def log_metadata_operation(operation:, table_name: nil, column_name: nil, success: true, error_message: nil)
          record("METADATA_#{operation.to_s.upcase}", success, error_message,
                 table: Sanitizer.table_name(table_name),
                 column: Sanitizer.column_name(column_name))
        end

        # @return [void]
        def log_configuration_change(config_type:, details: nil, success: true, error_message: nil)
          record('CONFIGURATION_CHANGE', success, error_message,
                 config_type: Sanitizer.truncate(config_type, Sanitizer::MAX_NAME_LENGTH),
                 details: Sanitizer.config_details(details))
        end

        # @return [void]
        def log_connection_parameter_extraction(strategy:, connection_type:, success: true, error_message: nil)
          record('CONNECTION_PARAMETER_EXTRACTION', success, error_message,
                 strategy: Sanitizer.truncate(strategy, Sanitizer::MAX_NAME_LENGTH),
                 connection_type: Sanitizer.truncate(connection_type, Sanitizer::MAX_NAME_LENGTH))
        end

        # @param active [Boolean] whether connection sharing is currently in effect
        # @return [void]
        def log_connection_sharing_fallback(reason:, original_failure: nil, active: false)
          return unless @enabled

          # The fallback deactivating (returning to normal) is worth an info record; while it is
          # active the steady state is logged at debug.
          emit(active ? :debug : :info, 'CONNECTION_SHARING_FALLBACK', true, nil,
               reason: Sanitizer.description(reason),
               original_failure: Sanitizer.error_message(original_failure),
               active: active)
        end

        # @return [void]
        def log_connection_health_check(connection_type:, healthy:, success_count:, failure_count:, success_rate:)
          return unless @enabled

          emit(healthy ? :info : :warn, 'CONNECTION_HEALTH_CHECK', healthy, nil,
               connection_type: Sanitizer.truncate(connection_type, Sanitizer::MAX_NAME_LENGTH),
               healthy: healthy,
               successful: success_count,
               failed: failure_count,
               success_rate: format('%.2f%%', success_rate * 100))
        end

        private

        def record(operation, success, error_message, fields)
          return unless @enabled

          emit(success ? :info : :warn, operation, success, error_message, fields)
        end

        def emit(level, operation, success, error_message, fields)
          logger.public_send(level, build_line(operation, success, error_message, fields))
        end

        def build_line(operation, success, error_message, fields)
          entries = { operation: operation, success: success }
          fields.each { |key, value| entries[key] = value unless value.nil? }
          entries[:error] = Sanitizer.error_message(error_message) if error_message
          entries[:timestamp] = Time.now.utc.iso8601

          "#{AUDIT_PREFIX} #{entries.map { |key, value| "#{key}=#{value}" }.join(' ')}"
        end
      end
    end
  end
end
