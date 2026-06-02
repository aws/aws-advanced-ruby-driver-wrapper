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

require_relative '../db_dialects/aurora_mysql_dialect'
require_relative '../db_dialects/aurora_pg_dialect'
require_relative '../db_dialects/dialect_codes'
require_relative '../db_dialects/global_mysql_dialect'
require_relative '../db_dialects/global_pg_dialect'
require_relative '../db_dialects/multi_az_cluster_mysql_dialect'
require_relative '../db_dialects/multi_az_cluster_pg_dialect'
require_relative '../db_dialects/mysql_dialect'
require_relative '../db_dialects/pg_dialect'
require_relative '../db_dialects/rds_mysql_dialect'
require_relative '../db_dialects/rds_pg_dialect'
require_relative '../db_dialects/unknown_dialect'
require_relative '../driver_dialects/driver_dialect_manager'
require_relative '../errors'
require_relative '../property_definition'
require_relative '../utils/rds_url_type'
require_relative '../utils/rds_utils'
require_relative '../utils/storage/expiration_cache'

module AwsRubyDatabaseDriverWrapper
  module Services
    class DialectService
      attr_reader :driver_dialect, :db_dialect

      ENDPOINT_CACHE_EXPIRATION = 86_400 # 24 hours in seconds

      @known_endpoint_dialects = Utils::Storage::ExpirationCache.new(ttl: ENDPOINT_CACHE_EXPIRATION)

      class << self
        attr_reader :known_endpoint_dialects
      end

      KNOWN_DIALECT_CLASSES = {
        DialectCodes::MYSQL => DbDialects::MysqlDialect,
        DialectCodes::RDS_MYSQL => DbDialects::RdsMysqlDialect,
        DialectCodes::AURORA_MYSQL => DbDialects::AuroraMysqlDialect,
        DialectCodes::GLOBAL_AURORA_MYSQL => DbDialects::GlobalMysqlDialect,
        DialectCodes::MULTI_AZ_MYSQL_CLUSTER => DbDialects::MultiAzClusterMysqlDialect,
        DialectCodes::PG => DbDialects::PgDialect,
        DialectCodes::RDS_PG => DbDialects::RdsPgDialect,
        DialectCodes::AURORA_PG => DbDialects::AuroraPgDialect,
        DialectCodes::GLOBAL_AURORA_PG => DbDialects::GlobalPgDialect,
        DialectCodes::MULTI_AZ_PG_CLUSTER => DbDialects::MultiAzClusterPgDialect,
        DialectCodes::UNKNOWN => DbDialects::UnknownDialect
      }.freeze

      # @param connection_service [ConnectionService]
      # @param driver_name [Symbol] :mysql2 or :postgresql
      def initialize(connection_service, driver_name)
        @connection_service = connection_service
        @dialect_cache = {}
        @can_update = false
        @driver_dialect = DriverDialects::DriverDialectManager.get_dialect(driver_name)
        @error_handler = DriverDialects::DriverDialectManager.get_error_handler(driver_name)
        @db_dialect = init_dialect
        @dialect_confirmed = false
      end

      # @return [Boolean] whether the dialect has been confirmed via a live connection query
      def dialect_confirmed?
        @dialect_confirmed
      end

      # Lazily instantiates and caches a dialect by code.
      #
      # @param code [String] the dialect code
      # @return [Object, nil] the dialect instance or nil if unknown
      def dialect_for_code(code)
        @dialect_cache[code] ||= begin
          known_class = KNOWN_DIALECT_CLASSES[code]
          known_class&.new(@driver_dialect)
        end
      end

      # @api private
      def can_update?
        @can_update
      end

      # Refines the dialect after a connection is established by querying the server
      # (e.g. checking for Aurora-specific functions/tables).
      #
      # @param connection [Object] the live database connection
      # @return [Object] the updated database dialect
      def update_dialect(connection_service, connection)
        original_dialect_code = @dialect_code

        if @can_update
          host = connection_service.initial_host_info&.host
          host_url = connection_service.initial_host_info&.url

          candidates = @db_dialect.dialect_update_candidates
          candidates&.each do |candidate_code|
            candidate = dialect_for_code(candidate_code)
            raise Errors::AwsError, "Unknown dialect code: #{candidate_code}" unless candidate

            next unless candidate.dialect?(connection)

            @can_update = false
            @dialect_code = candidate_code
            @db_dialect = candidate

            self.class.known_endpoint_dialects.put(host, candidate_code) if host
            self.class.known_endpoint_dialects.put(host_url, candidate_code) if host_url

            break
          end

          if @can_update
            # No candidate matched
            raise Errors::AwsError, 'Unable to determine dialect' if @dialect_code == DialectCodes::UNKNOWN

            @can_update = false
            self.class.known_endpoint_dialects.put(host, @dialect_code) if host
            self.class.known_endpoint_dialects.put(host_url, @dialect_code) if host_url
          end
        end

        @dialect_confirmed = true
        swap_host_list_provider if @dialect_code != original_dialect_code
        @db_dialect
      end

      # Creates the initial host list provider from the URL-guessed dialect.
      # Called after the service container is fully assembled.
      #
      # @param service_container [ServiceContainer]
      def setup_initial_provider(service_container)
        @service_container = service_container
        provider = @db_dialect.create_host_list_provider(service_container)
        service_container.host_service.host_list_provider = provider if provider
      end

      # @param error [Exception]
      # @return [Boolean]
      def network_error?(error)
        @error_handler.network_error?(error)
      end

      # @param error [Exception]
      # @return [Boolean]
      def login_error?(error)
        @error_handler.login_error?(error)
      end

      # @param error [Exception]
      # @return [Boolean]
      def read_only_error?(error)
        @error_handler.read_only_error?(error)
      end

      private

      # Resolves the initial database dialect from the initial connection info.
      # Uses RdsUtils to classify the host (Aurora cluster, RDS instance, etc.)
      # and selects the appropriate dialect.
      #
      # @return [Object] the resolved database dialect
      def init_dialect
        @can_update = false
        @db_dialect = nil

        user_dialect_setting = PropertyDefinition::DIALECT.get(@connection_service.wrapper_props)&.to_s
        host = @connection_service.initial_host_info&.host

        dialect_code = if user_dialect_setting.nil? || user_dialect_setting.empty?
                         self.class.known_endpoint_dialects.get(host) unless host.nil?
                       else
                         user_dialect_setting
                       end

        if dialect_code
          dialect = dialect_for_code(dialect_code)
          raise Errors::AwsError, "Unknown dialect code: #{dialect_code}" unless dialect

          @dialect_code = dialect_code
          @db_dialect = dialect
          return @db_dialect
        end

        rds_type = Utils::RdsUtils.identify_rds_type(host)

        @dialect_code = if @driver_dialect == DriverDialects::DriverDialectManager::MYSQL_DIALECT
                          resolve_mysql_dialect(rds_type)
                        elsif @driver_dialect == DriverDialects::DriverDialectManager::PG_DIALECT
                          resolve_pg_dialect(rds_type)
                        else
                          DialectCodes::UNKNOWN
                        end

        @db_dialect = dialect_for_code(@dialect_code)
        @db_dialect
      end

      def resolve_mysql_dialect(rds_type)
        if rds_type == Utils::RdsUrlType::RDS_GLOBAL_WRITER_CLUSTER
          @can_update = false
          DialectCodes::GLOBAL_AURORA_MYSQL
        elsif rds_type.rds_cluster?
          @can_update = true
          DialectCodes::AURORA_MYSQL
        elsif rds_type.rds?
          @can_update = true
          DialectCodes::RDS_MYSQL
        else
          @can_update = true
          DialectCodes::MYSQL
        end
      end

      def resolve_pg_dialect(rds_type)
        if rds_type == Utils::RdsUrlType::RDS_GLOBAL_WRITER_CLUSTER
          @can_update = false
          DialectCodes::GLOBAL_AURORA_PG
        elsif rds_type == Utils::RdsUrlType::RDS_AURORA_LIMITLESS_DB_SHARD_GROUP
          @can_update = false
          DialectCodes::AURORA_PG
        elsif rds_type.rds_cluster?
          @can_update = true
          DialectCodes::AURORA_PG
        elsif rds_type.rds?
          @can_update = true
          DialectCodes::RDS_PG
        else
          @can_update = true
          DialectCodes::PG
        end
      end

      def swap_host_list_provider
        return unless @service_container

        host_service = @service_container.host_service
        old_provider = host_service.host_list_provider
        old_provider&.stop_monitor

        new_provider = @db_dialect.create_host_list_provider(@service_container)
        host_service.host_list_provider = new_provider
      end
    end
  end
end
