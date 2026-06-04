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

require 'active_record/connection_adapters/postgresql_adapter'
require_relative '../postgresql'
require_relative '../utils/ar_constants'

module ActiveRecord
  module ConnectionAdapters
    class AwsPostgreSQLAdapter < PostgreSQLAdapter
      ADAPTER_NAME = 'AwsPostgreSQL'

      # ActiveRecord-only keys that should not be passed to the wrapper or native driver.
      AR_ONLY_KEYS = (AwsRubyDatabaseDriverWrapper::Utils::AR_COMMON_KEYS + %i[advisory_locks schema_search_path]).freeze

      # ActiveRecord uses :username and :database, but the PG gem expects :user and :dbname.
      # The parent adapter translates these in @connection_parameters, but also strips
      # non-PG keys (including wrapper properties) via slice!. Since we rebuild from @config
      # to preserve wrapper properties, we need to redo this translation ourselves.
      AR_TO_PG_KEY_MAP = { username: :user, database: :dbname }.freeze

      def initialize(...)
        # Capture the full config before the parent's initialize strips it
        # down to only PG-recognized keys in @connection_parameters.
        super
        @connection_broken = false
        @needs_reconfiguration = false
        # Store non-AR parameters in @wrapper_config.
        wrapper_config = @config.compact.except(*AR_ONLY_KEYS)
        # Remap ActiveRecord key names to PG gem key names.
        AR_TO_PG_KEY_MAP.each { |ar_key, pg_key| wrapper_config[pg_key] = wrapper_config.delete(ar_key) if wrapper_config.key?(ar_key) }
        @wrapper_config = wrapper_config
      end

      def adapter_name
        ADAPTER_NAME
      end

      # Note that this config includes wrapper properties.
      def self.new_client(config)
        AwsRubyDatabaseDriverWrapper::WrapperPgConnection.new(**config)
      end

      def connect
        @connection_broken = false
        # Override @connection_parameters with the full config so the parent's
        # call to new_client(@connection_parameters) includes wrapper properties.
        @connection_parameters = @wrapper_config
        super
      end

      def reconnect
        @connection_broken = false
        super
      end

      def active?
        return false if @connection_broken

        super
      end

      def verify!
        super

        return unless @needs_reconfiguration

        configure_connection
        @needs_reconfiguration = false
      end

      def translate_exception(exception, message:, sql:, binds:)
        return super unless exception.is_a?(AwsRubyDatabaseDriverWrapper::Errors::AwsError)

        if exception.is_a?(AwsRubyDatabaseDriverWrapper::Errors::FailoverSuccessError)
          @needs_reconfiguration = true
          exception
        elsif exception.is_a?(AwsRubyDatabaseDriverWrapper::Errors::FailoverFailedError)
          @connection_broken = true
          if defined?(ActiveRecord::ConnectionFailed)
            ActiveRecord::ConnectionFailed.new(message, sql: sql, binds: binds, connection_pool: @pool)
          else
            ActiveRecord::ConnectionNotEstablished.new(message)
          end
        else
          exception
        end
      end
    end
  end
end

if ActiveRecord::ConnectionAdapters.respond_to?(:register)
  ActiveRecord::ConnectionAdapters.register(
    'aws_postgresql',
    'ActiveRecord::ConnectionAdapters::AwsPostgreSQLAdapter',
    'aws_ruby_database_driver_wrapper/activerecord/aws_postgresql_adapter'
  )
end
