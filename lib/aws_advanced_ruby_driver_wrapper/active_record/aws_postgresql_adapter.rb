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
require_relative 'aws_connection_handler'

module ActiveRecord
  module ConnectionAdapters
    class AwsPostgreSQLAdapter < PostgreSQLAdapter
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

      # Report the underlying adapter name ("PostgreSQL"), not this wrapper's own name.
      def adapter_name = self.class.superclass::ADAPTER_NAME

      # Resolve native database types from the wrapped PostgreSQLAdapter rather than
      # maintaining a separate memoized copy on this subclass.
      def self.native_database_types
        superclass.native_database_types
      end

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

      # Used by db:drop, db:reset, db:test:prepare and db:purge. ActiveRecord disconnects its own
      # connections first, but the topology monitor shared by this cluster's connections, and the Blue/Green
      # status providers, keep their own connections to the database, and PostgreSQL refuses to drop a
      # database other sessions are using.
      def drop_database(name)
        raw_connection.stop_topology_monitor
        AwsAdvancedRubyDriverWrapper::Plugins::BlueGreen::BlueGreenPlugin.clean_up_providers
        super
      end

      def translate_exception(exception, message:, sql:, binds:)
        return super unless exception.is_a?(AwsAdvancedRubyDriverWrapper::Errors::AwsError)

        if exception.needs_reconfiguration
          # The wrapper has reconnected this connection object to a new physical connection, where the
          # statements prepared on the old one do not exist. Forget them so they are prepared again.
          clear_cache!(new_connection: true)
          configure_connection
          exception
        elsif exception.is_a?(AwsAdvancedRubyDriverWrapper::Errors::FailoverFailedError)
          @connection_broken = true
          ActiveRecord::ConnectionFailed.new(message, sql:, binds:, connection_pool: @pool)
        else
          exception
        end
      end

      # ActiveRecord's adapter-specific type registry (ActiveRecord::Type) keys every registration by
      # the *config adapter name*. The vanilla PostgreSQL adapter registers its OID types (:interval,
      # :point, :uuid, the array/range modifiers, etc.) under adapter: :postgresql, and a lookup uses
      # model.connection_db_config.adapter.to_sym as the key. Because this adapter's config name is
      # :aws_postgresql, none of those registrations match and `attribute :x, :interval` (or array/range
      # columns) raises "Unknown type".
      #
      # Mirror every :postgresql registration under :aws_postgresql so the wrapped adapter resolves the
      # exact same types. Done reflectively (rather than duplicating the hardcoded list) so it stays
      # correct across Rails versions as the PostgreSQL adapter adds or removes types.
      def self.mirror_postgresql_types!(target_adapter: :aws_postgresql, source_adapter: :postgresql)
        registry = ActiveRecord::Type.registry
        registrations = registry.instance_variable_get(:@registrations)
        return unless registrations

        mirrored = registrations.each_with_object([]) do |reg, acc|
          # name/adapter/override/block (and DecorationRegistration's options/klass) are protected
          # readers; read them within this contained reflection.
          next unless reg.send(:adapter) == source_adapter

          acc << mirror_registration(reg, target_adapter)
        end
        mirrored.each { |reg| registrations << reg unless registrations.include?(reg) }
      end

      def self.mirror_registration(reg, target_adapter)
        klass = reg.class
        if klass.name.end_with?('DecorationRegistration')
          # add_modifier form: options + decorator class.
          klass.new(reg.send(:options), reg.send(:klass), adapter: target_adapter)
        else
          klass.new(reg.send(:name), reg.send(:block), adapter: target_adapter, override: reg.send(:override))
        end
      end
    end
  end
end

ActiveRecord::ConnectionAdapters::AwsPostgreSQLAdapter.mirror_postgresql_types!

ActiveRecord::ConnectionAdapters.register(
  'aws_postgresql',
  'ActiveRecord::ConnectionAdapters::AwsPostgreSQLAdapter',
  'aws_advanced_ruby_driver_wrapper/active_record/aws_postgresql_adapter'
)
