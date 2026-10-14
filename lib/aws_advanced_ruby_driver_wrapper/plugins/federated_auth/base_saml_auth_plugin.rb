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
require_relative '../../errors'
require_relative '../../property_definition'
require_relative '../../utils/iam_auth_utils'
require_relative '../../utils/rds_utils'
require_relative '../../utils/rds_url_type'
require_relative '../../utils/saml_utils'

module AwsAdvancedRubyDriverWrapper
  module Plugins
    module FederatedAuth
      # Shared connect flow for the SAML-based authentication plugins (AD FS and
      # Okta).
      class BaseSamlAuthPlugin
        SUBSCRIBED_METHODS = Set['connect', 'internal_connect'].freeze
        # Shared with the IAM and Okta/AD FS plugins so a token minted by one is
        # visible to the others.
        IAM_TOKEN_CACHE_NAME = :iam_token

        attr_reader :subscribed_methods

        def initialize(service_container, props = ::Concurrent::Map.new)
          ensure_aws_sdk!
          @service_container = service_container
          @wrapper_props = props
          expiration = PropertyDefinition::IAM_EXPIRATION_SEC.get_float(props)
          PropertyDefinition::IAM_EXPIRATION_SEC.validate!(expiration)
          service_container.storage_service.register(IAM_TOKEN_CACHE_NAME, ttl: expiration)
          @subscribed_methods = SUBSCRIBED_METHODS
        end

        def connect(host_info, driver_props, _is_initial_connection, pipeline_callable)
          saml_connect(host_info, driver_props, pipeline_callable)
        end

        def internal_connect(host_info, driver_props, wrapper_props_override, _is_initial_connection, pipeline_callable)
          saml_connect(host_info, driver_props, pipeline_callable, wrapper_props_override || @wrapper_props)
        end

        def self.clear_cache(storage_service)
          storage_service.clear(IAM_TOKEN_CACHE_NAME)
        end

        # Exchanges a SAML assertion for temporary AWS credentials via STS
        # AssumeRoleWithSAML.
        #
        # @return [Aws::Credentials]
        def self.credentials_from_saml(saml_assertion, role_arn:, idp_arn:, region:)
          require 'aws-sdk-core'
          client_opts = {}
          client_opts[:region] = region if region && !region.to_s.empty?
          resp = Aws::STS::Client.new(**client_opts).assume_role_with_saml(
            role_arn:, principal_arn: idp_arn, saml_assertion:
          )
          creds = resp.credentials
          Aws::Credentials.new(creds.access_key_id, creds.secret_access_key, creds.session_token)
        end

        private

        def saml_connect(host_info, driver_props, pipeline_callable, wrapper_props_override = nil)
          wrapper_props_override ||= @wrapper_props
          saml_props = wrapper_props_override

          validate_required!(saml_props)

          db_user = PropertyDefinition::DB_USER.get(saml_props)
          # The IdP login defaults to the connection's user/password when idp_username
          # / idp_password are not given.
          idp_username = PropertyDefinition::IDP_USERNAME.get(saml_props) ||
                         driver_props[:user] || driver_props[:username]
          idp_password = PropertyDefinition::IDP_PASSWORD.get(saml_props) || driver_props[:password]

          host = Utils::IamAuthUtils.resolve_host(
            PropertyDefinition::IAM_HOST.get(wrapper_props_override), host_info
          )
          port = Utils::IamAuthUtils.resolve_port(
            PropertyDefinition::IAM_PORT.get(wrapper_props_override),
            host_info,
            @service_container.dialect_service.db_dialect.default_port
          )
          rds_type = Utils::RdsUtils.identify_rds_type(host)

          # A global writer cluster needs AWS credentials to resolve its region, so
          # the SAML exchange has to happen before the region lookup (and therefore
          # before the token-cache check) for those endpoints only.
          preassumed_credentials = nil
          if rds_type == Utils::RdsUrlType::RDS_GLOBAL_WRITER_CLUSTER
            preassumed_credentials = obtain_credentials(saml_props, nil, idp_username, idp_password)
          end

          region = Utils::IamAuthUtils.region_for(
            host:, props: wrapper_props_override, rds_type:,
            credentials_provider: preassumed_credentials,
            rds_client_func: preassumed_credentials ? -> { Aws::RDS::Client.new(credentials: preassumed_credentials) } : nil
          )
          unless region
            raise Errors::SamlAuthError,
                  "#{self.class.name}: unable to determine connection region. " \
                  "If you are using a non-standard RDS URL, please set the 'iam_region' property."
          end

          fingerprint = Utils::SamlUtils.principal_fingerprint(
            PropertyDefinition::IAM_ROLE_ARN.get(saml_props),
            PropertyDefinition::IAM_IDP_ARN.get(saml_props)
          )
          cache_key = Utils::IamAuthUtils.cache_key(region, host, port, db_user, fingerprint)
          entry = @service_container.storage_service.get(IAM_TOKEN_CACHE_NAME, cache_key)
          expiration = PropertyDefinition::IAM_EXPIRATION_SEC.get_float(wrapper_props_override)
          PropertyDefinition::IAM_EXPIRATION_SEC.validate!(expiration)

          if Utils::IamAuthUtils.valid_entry?(entry)
            token = entry.token
            is_cached_token = true
          else
            token = fetch_and_cache_token(saml_props, region, host, port, db_user, cache_key, expiration,
                                          idp_username, idp_password, preassumed_credentials)
            is_cached_token = false
          end

          user_key = @service_container.dialect_service.driver_dialect.user_property_key
          driver_props[user_key] = db_user
          driver_props[:password] = token

          begin
            pipeline_callable.call
          rescue StandardError => e
            raise unless is_cached_token && @service_container.dialect_service.login_error?(e)

            driver_props[:password] = fetch_and_cache_token(saml_props, region, host, port, db_user, cache_key,
                                                            expiration, idp_username, idp_password, nil)
            pipeline_callable.call
          end
        end

        # Mints a fresh RDS token signed with SAML-derived credentials and caches it.
        def fetch_and_cache_token(saml_props, region, host, port, db_user, cache_key, expiration,
                                  idp_username, idp_password, credentials)
          credentials ||= obtain_credentials(saml_props, region, idp_username, idp_password)
          token = Utils::IamAuthUtils.generate_token(
            region:, hostname: host, port:, user: db_user, credentials_provider: credentials
          )
          @service_container.storage_service.set(
            IAM_TOKEN_CACHE_NAME, cache_key, Utils::IamAuthUtils.build_token_entry(token, expiration)
          )
          token
        end

        # Fetches a SAML assertion from the IdP and exchanges it for AWS credentials.
        def obtain_credentials(saml_props, region, idp_username, idp_password)
          assertion = self.class.fetch_saml_assertion(
            **saml_fetch_options(saml_props, idp_username, idp_password)
          )
          self.class.credentials_from_saml(
            assertion,
            role_arn: PropertyDefinition::IAM_ROLE_ARN.get(saml_props),
            idp_arn: PropertyDefinition::IAM_IDP_ARN.get(saml_props),
            region:
          )
        end

        def validate_required!(saml_props)
          missing = required_identity(saml_props).select { |_name, value| value.nil? || value.to_s.empty? }
          return if missing.empty?

          names = missing.map(&:first)
          raise Errors::SamlAuthError,
                "#{self.class.name}: #{names.join(', ')} #{names.length > 1 ? 'are' : 'is'} required"
        end

        # The properties that must be present for this IdP. Subclasses override to
        # append their own (e.g. Okta's app_id).
        def required_identity(saml_props)
          [
            ['db_user', PropertyDefinition::DB_USER.get(saml_props)],
            ['idp_endpoint', PropertyDefinition::IDP_ENDPOINT.get(saml_props)],
            ['iam_role_arn', PropertyDefinition::IAM_ROLE_ARN.get(saml_props)],
            ['iam_idp_arn', PropertyDefinition::IAM_IDP_ARN.get(saml_props)]
          ]
        end

        # The keyword arguments passed to .fetch_saml_assertion. Subclasses override.
        def saml_fetch_options(saml_props, idp_username, idp_password)
          {
            idp_endpoint: PropertyDefinition::IDP_ENDPOINT.get(saml_props),
            idp_username:,
            idp_password:,
            ssl_insecure: PropertyDefinition::SSL_INSECURE.get_bool(saml_props),
            socket_timeout_ms: PropertyDefinition::HTTP_CLIENT_SOCKET_TIMEOUT.get_int(saml_props),
            connect_timeout_ms: PropertyDefinition::HTTP_CLIENT_CONNECT_TIMEOUT.get_int(saml_props)
          }
        end

        def ensure_aws_sdk!
          require 'aws-sdk-rds'
        rescue LoadError
          raise LoadError,
                "The SAML auth plugins require 'aws-sdk-rds'. Add it to your Gemfile: gem 'aws-sdk-rds'"
        end
      end
    end
  end
end
