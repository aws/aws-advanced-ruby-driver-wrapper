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

require_relative '../errors'
require_relative '../utils/iam_auth_utils'
require_relative '../utils/rds_utils'
require_relative '../utils/rds_url_type'
require_relative '../driver_dialects/driver_dialect_manager'
require_relative '../property_definition'

module AwsRubyDatabaseDriverWrapper
  module Plugins
    class IamAuthPlugin
      SUBSCRIBED_METHODS = Set['connect', 'internal_connect'].freeze
      CACHE_NAME = :iam_token
      DEFAULT_TOKEN_EXPIRATION_SEC = 870

      attr_reader :subscribed_methods

      def initialize(service_container, props = {})
        ensure_aws_sdk!
        @service_container = service_container
        @props = props
        @credentials_provider = props[:iam_credentials_provider] ||
                                Aws::RDS::Client.new.config.credentials
        expiration = (props[:iam_expiration] || DEFAULT_TOKEN_EXPIRATION_SEC).to_i
        service_container.storage_service.register(CACHE_NAME, ttl: expiration)
        @subscribed_methods = SUBSCRIBED_METHODS
      end

      def connect(host_info, props, _is_initial_connection, pipeline_callable)
        connect_internal(host_info, props, pipeline_callable)
      end

      def internal_connect(host_info, props, _wrapper_override_props, _is_initial_connection, pipeline_callable)
        connect_internal(host_info, props, pipeline_callable)
      end

      def self.clear_cache(storage_service)
        storage_service.clear(CACHE_NAME)
      end

      private

      def connect_internal(host_info, props, pipeline_callable)
        user = props[:user] || props[:username]
        raise Errors::IamAuthError, 'IamAuthPlugin: :user is required' if user.nil? || user.empty?

        token_prop = (props[:iam_access_token_property_name] || :password).to_sym

        host = Utils::IamAuthUtils.resolve_host(props[:iam_host], host_info)
        port = Utils::IamAuthUtils.resolve_port(
          props[:iam_default_port],
          host_info,
          @service_container.dialect_service.db_dialect.default_port
        )
        rds_type = Utils::RdsUtils.identify_rds_type(host)
        region   = Utils::IamAuthUtils.region_for(
          host:, props:, rds_type:, credentials_provider: @credentials_provider
        )
        unless region
          raise Errors::IamAuthError,
                'IamAuthPlugin: unable to determine AWS region; set :iam_region or use an RDS hostname'
        end

        cache_key  = Utils::IamAuthUtils.cache_key(region, host, port, user)
        entry      = @service_container.storage_service.get(CACHE_NAME, cache_key)
        expiration = (@props[:iam_expiration] || DEFAULT_TOKEN_EXPIRATION_SEC).to_i

        if Utils::IamAuthUtils.valid_entry?(entry)
          props[token_prop] = entry.token
          is_cached_token   = true
        else
          token = Utils::IamAuthUtils.generate_token(
            region:, hostname: host, port:, user:, credentials_provider: @credentials_provider
          )
          props[token_prop] = token
          @service_container.storage_service.set(
            CACHE_NAME, cache_key, Utils::IamAuthUtils.build_token_entry(token, expiration)
          )
          is_cached_token = false
        end

        if @service_container.dialect_service.driver_dialect == DriverDialects::DriverDialectManager::MYSQL_DIALECT
          props[:enable_cleartext_plugin] = true
        end

        begin
          pipeline_callable.call
        rescue StandardError => e
          raise unless is_cached_token && @service_container.dialect_service.login_error?(e)

          token = Utils::IamAuthUtils.generate_token(
            region:, hostname: host, port:, user:, credentials_provider: @credentials_provider
          )
          props[token_prop] = token
          @service_container.storage_service.set(
            CACHE_NAME, cache_key, Utils::IamAuthUtils.build_token_entry(token, expiration)
          )
          pipeline_callable.call
        end
      end

      def ensure_aws_sdk!
        require 'aws-sdk-rds'
      rescue LoadError
        raise LoadError,
              "The IAM auth plugin requires 'aws-sdk-rds'. Add it to your Gemfile: gem 'aws-sdk-rds'"
      end
    end
  end
end
