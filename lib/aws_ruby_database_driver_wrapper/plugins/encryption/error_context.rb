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
      # Builds the human readable, redacted message that goes with an encryption failure.
      #
      #   ErrorContext.builder
      #               .table('users').column('ssn').operation('ENCRYPT').parameter_index(2)
      #               .build_encryption_error_message('the data key was rejected')
      #   # => "Encryption failed: the data key was rejected for column users.ssn during ENCRYPT (parameter index: 2)"
      #
      # Sensitive details are redacted by {Sanitizer} as they are added, so a context can be
      # logged or attached to an exception message as is.
      class ErrorContext
        # Keys rendered inline by the +build_*_error_message+ helpers rather than in the
        # trailing bracketed list.
        POSITIONAL_KEYS = %i[table column operation parameter_index column_index retry_attempt max_retry_attempts].freeze

        # @return [ErrorContext] a new, empty context
        def self.builder
          new
        end

        def initialize
          @context = {}
        end

        # @return [self]
        def table(table_name)
          put(:table, Sanitizer.table_name(table_name))
        end

        # @return [self]
        def column(column_name)
          put(:column, Sanitizer.column_name(column_name))
        end

        # @return [self]
        def operation(operation)
          put(:operation, operation)
        end

        # @return [self]
        def key_id(key_id)
          put(:key_id, Sanitizer.key_id(key_id))
        end

        # @return [self]
        def master_key_arn(master_key_arn)
          put(:master_key_arn, Sanitizer.arn(master_key_arn))
        end

        # @return [self]
        def algorithm(algorithm)
          put(:algorithm, algorithm)
        end

        # @return [self]
        def parameter_index(index)
          put(:parameter_index, index)
        end

        # @return [self]
        def column_index(index)
          put(:column_index, index)
        end

        # @return [self]
        def sql(sql)
          put(:sql, Sanitizer.sql(sql))
        end

        # @return [self]
        def data_type(data_type)
          put(:data_type, data_type)
        end

        # @param attempt [Integer] the attempt that failed, 1-based
        # @param max_attempts [Integer]
        # @return [self]
        def retry_attempt(attempt, max_attempts)
          put(:retry_attempt, attempt)
          put(:max_retry_attempts, max_attempts)
        end

        # @param cache_type [String]
        # @param cache_hit [Boolean]
        # @return [self]
        def cache_info(cache_type, cache_hit)
          put(:cache_type, cache_type)
          put(:cache_hit, cache_hit)
        end

        # @return [Hash] a copy of the accumulated context
        def context
          @context.dup
        end

        # @return [Boolean]
        def empty?
          @context.empty?
        end

        # @param base_message [String]
        # @return [String] the message with the whole context appended as key=value pairs
        def build_message(base_message)
          return base_message.to_s if @context.empty?

          "#{base_message} [Context: #{@context.map { |key, value| "#{key}=#{value}" }.join(', ')}]"
        end

        # @return [String]
        def build_encryption_error_message(base_message = nil)
          build_prefixed_message('Encryption failed', base_message)
        end

        # @return [String]
        def build_decryption_error_message(base_message = nil)
          build_prefixed_message('Decryption failed', base_message)
        end

        # @return [String]
        def build_key_management_error_message(base_message = nil)
          build_prefixed_message('Key management operation failed', base_message)
        end

        # @return [String]
        def build_metadata_error_message(base_message = nil)
          build_prefixed_message('Metadata operation failed', base_message)
        end

        private

        def put(key, value)
          @context[key] = value unless value.nil?
          self
        end

        def build_prefixed_message(prefix, base_message)
          message = +prefix
          message << ": #{base_message}" unless base_message.nil? || base_message.to_s.strip.empty?
          add_contextual_info(message)
        end

        def add_contextual_info(message)
          message << target_description
          message << " during #{@context[:operation]}" if @context[:operation]
          message << index_description
          message << " (retry #{@context[:retry_attempt]}/#{@context[:max_retry_attempts]})" if @context[:retry_attempt]
          message << remaining_description
          message
        end

        def target_description
          table_name = @context[:table]
          column_name = @context[:column]

          if table_name && column_name then " for column #{table_name}.#{column_name}"
          elsif table_name then " for table #{table_name}"
          elsif column_name then " for column #{column_name}"
          else ''
          end
        end

        def index_description
          if @context[:parameter_index] then " (parameter index: #{@context[:parameter_index]})"
          elsif @context[:column_index] then " (column index: #{@context[:column_index]})"
          else ''
          end
        end

        def remaining_description
          remaining = @context.except(*POSITIONAL_KEYS)
          return '' if remaining.empty?

          " [#{remaining.map { |key, value| "#{key}=#{value}" }.join(', ')}]"
        end
      end
    end
  end
end
