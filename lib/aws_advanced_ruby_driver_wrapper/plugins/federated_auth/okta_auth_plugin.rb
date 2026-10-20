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

require 'cgi'
require 'json'
require_relative 'base_saml_auth_plugin'

module AwsAdvancedRubyDriverWrapper
  module Plugins
    module FederatedAuth
      # Federated authentication against Okta. Authenticates to Okta's /authn API
      # for a one-time session token, redeems it at the AWS app's SSO SAML endpoint
      # for a SAML assertion, and then defers to BaseSamlAuthPlugin for the STS
      # exchange, token minting, caching, and retry. Okta differs from AD FS only in
      # configuration (it uses app_id, the AWS app configured on Okta) and in the
      # shape of the IdP HTTP flow.
      class OktaAuthPlugin < AwsAdvancedRubyDriverWrapper::Plugins::FederatedAuth::BaseSamlAuthPlugin
        OKTA_AWS_APP_NAME = 'amazon_aws'
        # Extracts the value attribute of the hidden SAMLResponse input regardless
        # of attribute order.
        SAML_INPUT_PATTERN = /<input[^>]*\bname="SAMLResponse"[^>]*>/i
        VALUE_ATTR_PATTERN = /\bvalue="([^"]+)"/i

        # Fetches a SAML assertion from Okta.
        #
        # @return [String] the base64 SAML assertion
        def self.fetch_saml_assertion(idp_endpoint:, app_id:, idp_username:, idp_password:,
                                      ssl_insecure:, socket_timeout_sec:, connect_timeout_sec:, **_rest)
          http = lambda do |method, url, body: nil, headers: {}|
            Utils::SamlUtils.http_request(
              method:, url:, body:, headers:, ssl_insecure:,
              open_timeout_sec: connect_timeout_sec, read_timeout_sec: socket_timeout_sec
            )
          end

          session_token = session_token(http, idp_endpoint, idp_username, idp_password)
          saml_url = "https://#{idp_endpoint}/app/#{OKTA_AWS_APP_NAME}/#{CGI.escape(app_id)}/sso/saml" \
                     "?onetimetoken=#{CGI.escape(session_token)}"
          response = http.call(:get, saml_url)
          unless response.is_a?(Net::HTTPSuccess)
            raise Errors::SamlAuthError,
                  "OktaAuthPlugin: SAML request failed (#{response.code} #{response.message})"
          end

          tag = SAML_INPUT_PATTERN.match(response.body)
          value = tag && VALUE_ATTR_PATTERN.match(tag[0])
          raise Errors::SamlAuthError, 'OktaAuthPlugin: invalid SAML response from Okta' unless value

          # The value attribute is HTML-entity-encoded (Okta encodes base64's trailing
          # "=" padding, and "+" if present, as e.g. &#x3d; / &#x2b;); decode before
          # handing the assertion to STS, matching FederatedAuthPlugin's AD FS flow.
          CGI.unescapeHTML(value[1])
        end

        # Authenticates to Okta's /authn API and returns the one-time session token.
        def self.session_token(http, idp_endpoint, idp_username, idp_password)
          response = http.call(
            :post, "https://#{idp_endpoint}/api/v1/authn",
            body: JSON.generate(username: idp_username, password: idp_password),
            headers: { 'Accept' => 'application/json', 'Content-Type' => 'application/json' }
          )
          unless response.is_a?(Net::HTTPSuccess)
            raise Errors::SamlAuthError,
                  "OktaAuthPlugin: Okta session token request failed (#{response.code} #{response.message})"
          end

          parsed = begin
            JSON.parse(response.body)
          rescue JSON::ParserError
            nil
          end
          parsed = nil unless parsed.is_a?(Hash)
          token = parsed && parsed['sessionToken']
          if token.nil? || token.empty?
            # Okta's `status` is a non-sensitive auth-state enum (e.g. MFA_REQUIRED,
            # PASSWORD_EXPIRED, LOCKED_OUT); surface it for clarity. It never carries
            # credentials or the session token itself.
            status = parsed && parsed['status']
            detail = status.is_a?(String) && !status.empty? ? " (status: #{status})" : ''
            raise Errors::SamlAuthError, "OktaAuthPlugin: Okta did not return a session token#{detail}"
          end

          token
        end

        private

        def required_identity(saml_props)
          super + [['app_id', PropertyDefinition::APP_ID.get(saml_props)]]
        end

        def saml_fetch_options(saml_props, idp_username, idp_password)
          super.merge(app_id: PropertyDefinition::APP_ID.get(saml_props))
        end
      end
    end
  end
end
