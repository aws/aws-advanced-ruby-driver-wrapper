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

require 'concurrent'
require_relative '../errors'
require_relative '../utils/iam_auth_utils'
require_relative '../utils/rds_utils'
require_relative '../utils/rds_url_type'
require_relative '../driver_dialects/driver_dialect_manager'
require_relative '../property_definition'

module AwsAdvancedRubyDriverWrapper
  module Plugins
    class IamAuthPlugin
      SUBSCRIBED_METHODS = Set['connect', 'internal_connect'].freeze
      IAM_TOKEN_CACHE_NAME = :iam_token

      attr_reader :subscribed_methods

      def initialize(service_container, props = ::Concurrent::Map.new)
        ensure_aws_sdk!
        @service_container = service_container
        @wrapper_props = props
        @credentials_provider = PropertyDefinition::AWS_CREDENTIALS_PROVIDER.get(props) ||
                                Aws::CredentialProviderChain.new.resolve
        expiration = PropertyDefinition::IAM_EXPIRATION.get_int(props)
        service_container.storage_service.register(IAM_TOKEN_CACHE_NAME, ttl: expiration)
        @subscribed_methods = SUBSCRIBED_METHODS
      end

      def connect(host_info, driver_props, _is_initial_connection, pipeline_callable)
        iam_connect(host_info, driver_props, pipeline_callable)
      end

      def internal_connect(host_info, driver_props, wrapper_props_override, _is_initial_connection, pipeline_callable)
        iam_connect(host_info, driver_props, pipeline_callable, wrapper_props_override || @wrapper_props)
      end

      def self.clear_cache(storage_service)
        storage_service.clear(IAM_TOKEN_CACHE_NAME)
      end

      private

      def iam_connect(host_info, driver_props, pipeline_callable, wrapper_props_override = nil)
        wrapper_props_override ||= @wrapper_props

        user = driver_props[:user] || driver_props[:username]
        raise Errors::IamAuthError, 'IamAuthPlugin: :user is required' if user.nil? || user.empty?

        host = Utils::IamAuthUtils.resolve_host(
          PropertyDefinition::IAM_HOST.get(wrapper_props_override), host_info
        )
        rds_type = Utils::RdsUtils.identify_rds_type(host)
        begin
          region = Utils::IamAuthUtils.region_for(
            host:, props: wrapper_props_override, rds_type:, credentials_provider: @credentials_provider,
            rds_client_func: -> { rds_client }
          )
        rescue Aws::Errors::MissingRegionError
          raise Errors::IamAuthError,
                'IamAuthPlugin: unable to determine connection region. ' \
                "If you are using a non-standard RDS URL, please set the 'iam_region' property."
        end
        unless region
          raise Errors::IamAuthError,
                'IamAuthPlugin: unable to determine connection region. ' \
                "If you are using a non-standard RDS URL, please set the 'iam_region' property."
        end

        token_prop = PropertyDefinition::IAM_ACCESS_TOKEN_PROPERTY_NAME.get(wrapper_props_override).to_sym

        port = Utils::IamAuthUtils.resolve_port(
          PropertyDefinition::IAM_PORT.get(wrapper_props_override),
          host_info,
          @service_container.dialect_service.db_dialect.default_port
        )

        cache_key  = Utils::IamAuthUtils.cache_key(region, host, port, user)
        entry      = @service_container.storage_service.get(IAM_TOKEN_CACHE_NAME, cache_key)
        expiration = PropertyDefinition::IAM_EXPIRATION.get_int(wrapper_props_override)

        if Utils::IamAuthUtils.valid_entry?(entry)
          driver_props[token_prop] = entry.token
          is_cached_token = true
        else
          driver_props[token_prop] = fetch_and_cache_token(region, host, port, user, cache_key, expiration)
          is_cached_token = false
        end

        if @service_container.dialect_service.driver_dialect == DriverDialects::DriverDialectManager::MYSQL_DIALECT
          driver_props[:enable_cleartext_plugin] = true
        end

        begin
          pipeline_callable.call
        rescue StandardError => e
          raise unless is_cached_token && @service_container.dialect_service.login_error?(e)

          driver_props[token_prop] = fetch_and_cache_token(region, host, port, user, cache_key, expiration)
          pipeline_callable.call
        end
      end

      def fetch_and_cache_token(region, host, port, user, cache_key, expiration)
        token = token_generator.auth_token(region:, endpoint: "#{host}:#{port}", user_name: user)
        @service_container.storage_service.set(
          IAM_TOKEN_CACHE_NAME, cache_key, Utils::IamAuthUtils.build_token_entry(token, expiration)
        )
        token
      end

      def token_generator
        @token_generator ||= Aws::RDS::AuthTokenGenerator.new(credentials: @credentials_provider)
      end

      def rds_client
        @rds_client ||= begin
          region = PropertyDefinition::IAM_REGION.get(@wrapper_props)
          Aws::RDS::Client.new(
            credentials: @credentials_provider,
            **(region ? { region: region } : {})
          )
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
