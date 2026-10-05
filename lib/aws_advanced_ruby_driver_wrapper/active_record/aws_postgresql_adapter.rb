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
require_relative '../errors'

module ActiveRecord
  module ConnectionAdapters
    class AwsPostgreSQLAdapter < PostgreSQLAdapter
      ADAPTER_NAME = 'AwsPostgreSQL'

      # ActiveRecord uses :username and :database, but the PG gem expects :user and :dbname.
      # The parent adapter translates these in @connection_parameters, but also strips
      # non-PG keys (including wrapper properties) via slice!. Since we rebuild from @config
      # to preserve wrapper properties, we need to redo this translation ourselves.
      AR_TO_PG_KEY_MAP = { username: :user, database: :dbname }.freeze

      # The connection options PG accepts, the same set the parent adapter forwards.
      PG_CONNECTION_KEYS = (PG::Connection.conndefaults_hash.keys + [:requiressl]).to_set.freeze

      def initialize(...)
        # Capture the full config before the parent's initialize strips it
        # down to only PG-recognized keys in @connection_parameters.
        super
        @connection_broken = false
        wrapper_config = @config.compact
        # Remap ActiveRecord key names to PG gem key names.
        AR_TO_PG_KEY_MAP.each { |ar_key, pg_key| wrapper_config[pg_key] = wrapper_config.delete(ar_key) if wrapper_config.key?(ar_key) }
        # Keep only what PG or the wrapper understands. Every other key is an ActiveRecord setting,
        # and PG rejects any connection option it does not recognize.
        @wrapper_config = wrapper_config.select { |key, _| self.class.forwarded_key?(key) }
      end

      # @return [Boolean] whether the config key is passed on to the wrapper connection
      def self.forwarded_key?(key)
        PG_CONNECTION_KEYS.include?(key) ||
          AwsAdvancedRubyDriverWrapper::PropertyDefinition.wrapper_property?(key) ||
          AwsAdvancedRubyDriverWrapper::PropertyDefinition::KNOWN_PREFIXES.any? { |prefix| key.to_s.start_with?(prefix) }
      end

      def adapter_name = ADAPTER_NAME

      # Note that this config includes wrapper properties.
      #
      # Translates connection errors the same way the parent adapter does, so ActiveRecord can tell a
      # missing database (which db:prepare creates) or rejected credentials from other failures.
      def self.new_client(config)
        AwsAdvancedRubyDriverWrapper::WrapperPgConnection.new(**config)
      rescue ::PG::Error => e
        dbname, user, host = config.values_at(:dbname, :user, :host)
        # The postgres maintenance database always exists, so a failure there is not a missing database.
        raise ActiveRecord::ConnectionNotEstablished, e.message if dbname == 'postgres'
        raise ActiveRecord::NoDatabaseError.db_error(dbname) if dbname && e.message.include?(dbname)
        raise ActiveRecord::DatabaseConnectionError.username_error(user) if user && e.message.include?(user)
        raise ActiveRecord::DatabaseConnectionError.hostname_error(host) if host && e.message.include?(host)

        raise ActiveRecord::ConnectionNotEstablished, e.message
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

      def translate_exception(exception, message:, sql:, binds:)
        return super unless exception.is_a?(AwsAdvancedRubyDriverWrapper::Errors::AwsError)

        if exception.needs_reconfiguration
          configure_connection
          exception
        elsif exception.is_a?(AwsAdvancedRubyDriverWrapper::Errors::FailoverFailedError)
          @connection_broken = true
          ActiveRecord::ConnectionFailed.new(message, sql:, binds:, connection_pool: @pool)
        else
          exception
        end
      end
    end
  end
end

ActiveRecord::ConnectionAdapters.register(
  'aws_postgresql',
  'ActiveRecord::ConnectionAdapters::AwsPostgreSQLAdapter',
  'aws_advanced_ruby_driver_wrapper/active_record/aws_postgresql_adapter'
)
