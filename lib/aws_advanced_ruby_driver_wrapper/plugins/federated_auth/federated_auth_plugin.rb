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
require 'uri'
require_relative 'base_saml_auth_plugin'

module AwsAdvancedRubyDriverWrapper
  module Plugins
    module FederatedAuth
      # Federated authentication against Active Directory Federation Services
      # (AD FS). Scrapes the IdP-initiated sign-on page for its form, posts the
      # federated credentials, and extracts the SAML assertion from the response.
      # Everything else (STS exchange, token minting, caching, retry) is handled by
      # BaseSamlAuthPlugin.
      class FederatedAuthPlugin < BaseSamlAuthPlugin
        INPUT_TAG_PATTERN = /<input([^<>]*)>/
        FORM_ACTION_PATTERN = /<form[^<>]*?\baction="([^"]+)"/

        # Fetches a SAML assertion from AD FS.
        #
        # @return [String] the base64 SAML assertion
        def self.fetch_saml_assertion(idp_endpoint:, idp_port:, idp_username:, idp_password:,
                                      rp_identifier:, ssl_insecure:, socket_timeout_sec:, connect_timeout_sec:, **_rest)
          # One cookie jar shared by the sign-on GET and the credential POST, so cookies AD FS
          # (or a load balancer in front of it) sets on the sign-on page are returned with the POST.
          cookies = {}
          http = lambda do |method, url, body: nil, headers: {}|
            Utils::SamlUtils.http_request(
              method:, url:, body:, headers:, ssl_insecure:, cookies:,
              open_timeout_sec: connect_timeout_sec, read_timeout_sec: socket_timeout_sec
            )
          end

          sign_in_url = "https://#{idp_endpoint}:#{idp_port}/adfs/ls/IdpInitiatedSignOn.aspx?loginToRp=#{rp_identifier}"
          sign_in_body = require_body!(http.call(:get, sign_in_url), 'sign-on page')

          action = form_action(sign_in_body)
          post_url = action&.start_with?('/') ? "https://#{idp_endpoint}:#{idp_port}#{action}" : sign_in_url

          params = form_parameters(sign_in_body, idp_username, idp_password)
          response = http.call(:post, post_url,
                               body: URI.encode_www_form(params),
                               headers: { 'Content-Type' => 'application/x-www-form-urlencoded' })
          content = require_body!(response, 'sign-on POST')

          match = Utils::SamlUtils::SAML_RESPONSE_PATTERN.match(content)
          unless match
            # AD FS answers a rejected login with the sign-on page again (no SAMLResponse); the
            # body is not included as it may contain sensitive markup.
            raise Errors::SamlAuthError,
                  'FederatedAuthPlugin: no SAML assertion in the AD FS response - check idp_username, ' \
                  'idp_password, and idp_endpoint'
          end

          match[1]
        end

        def self.require_body!(response, what)
          return response.body if response.is_a?(Net::HTTPSuccess)

          raise Errors::SamlAuthError,
                "FederatedAuthPlugin: AD FS #{what} request failed (#{response.code} #{response.message})"
        end

        def self.form_action(body)
          match = FORM_ACTION_PATTERN.match(body)
          match && unescape_html(match[1])
        end

        # Builds the POST parameters from the sign-on form's input tags, filling in
        # the federated username/password and preserving every other hidden field.
        def self.form_parameters(body, idp_username, idp_password)
          params = []
          seen = {}
          body.scan(INPUT_TAG_PATTERN).flatten.each do |tag|
            name = value_by_key(tag, 'name')
            next if name.empty?

            lower = name.downcase
            next if seen[lower]

            seen[lower] = true
            value = value_by_key(tag, 'value')

            if lower.include?('username')
              params << [name, idp_username]
            elsif lower.include?('authmethod')
              params << [name, value] unless value.empty?
            elsif lower.include?('password')
              params << [name, idp_password]
            else
              params << [name, value]
            end
          end
          params
        end

        def self.value_by_key(input, key)
          match = /#{Regexp.quote(key)}\s*=\s*"(.*?)"/.match(input)
          match ? unescape_html(match[1]) : ''
        end

        def self.unescape_html(html)
          CGI.unescapeHTML(html)
        end

        private

        def saml_fetch_options(saml_props, idp_username, idp_password)
          super.merge(
            idp_port: PropertyDefinition::IDP_PORT.get(saml_props),
            rp_identifier: PropertyDefinition::RP_IDENTIFIER.get(saml_props)
          )
        end
      end
    end
  end
end
