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

require 'digest'
require 'net/http'
require 'openssl'
require 'uri'
require_relative '../errors'

module AwsAdvancedRubyDriverWrapper
  module Utils
    # Shared helpers for the SAML-based authentication plugins (AD FS, Okta):
    # URL validation, the cache-key principal fingerprint, and a small Net::HTTP
    # client used to talk to the identity provider's HTTP endpoints (there is no
    # AWS SDK for these calls).
    module SamlUtils
      module_function

      HTTPS_URL_PATTERN = %r{\Ahttps://[-a-zA-Z0-9+&@#/%?=~_!:,.']*[-a-zA-Z0-9+&@#/%=~_']}

      # The regex the IdP sign-in response is scraped with for the SAML assertion,
      # shared by the AD FS and Okta flows.
      SAML_RESPONSE_PATTERN = /SAMLResponse\W+value="([^"]+)"/

      # Rejects anything that is not a well-formed https:// URL, guarding the IdP
      # requests against being redirected to a non-TLS or malformed endpoint.
      #
      # @raise [Errors::SamlAuthError] when the URL is not a valid https URL
      def validate_url!(url)
        uri = URI.parse(url)
        return if uri.is_a?(URI::HTTPS) && url.match?(HTTPS_URL_PATTERN)

        raise Errors::SamlAuthError, "Invalid HTTPS URL: #{url}"
      rescue URI::InvalidURIError
        raise Errors::SamlAuthError, "Invalid HTTPS URL: #{url}"
      end

      # A short, stable fingerprint of the AWS principal a SAML connection assumes,
      # for the token cache key. The principal is fully determined by the STS
      # inputs iam_role_arn + iam_idp_arn, so two connections that assume different
      # roles (or trust different identity providers) never share a cached token.
      # No secret is included, and the federated username is intentionally excluded:
      # once the role is assumed the database authority is the role.
      #
      # @param parts [Array<String, nil>] role_arn, idp_arn
      # @return [String] 16 hex characters
      def principal_fingerprint(*parts)
        Digest::SHA256.hexdigest(parts.join("\0"))[0, 16]
      end

      # Performs an HTTP request against an IdP endpoint, following redirects and
      # carrying cookies across them (AD FS and Okta both rely on this). Only
      # https URLs are allowed; each hop is validated.
      #
      # @param method [Symbol] :get or :post
      # @param url [String] the https URL to request
      # @param body [String, nil] request body for :post
      # @param headers [Hash] request headers
      # @param ssl_insecure [Boolean] skip TLS verification when true
      # @param open_timeout_sec [Float] connect timeout in seconds
      # @param read_timeout_sec [Float] socket timeout in seconds
      # @param cookies [Hash] a cookie jar, keyed by host then cookie name, shared across the
      #   calls of one sign-on flow and mutated in place. Cookies are only sent back to the host
      #   that set them, so following a redirect to another host cannot leak them.
      # @return [Net::HTTPResponse]
      def http_request(method:, url:, body: nil, headers: {}, ssl_insecure: false,
                       open_timeout_sec: 60.0, read_timeout_sec: 60.0, max_redirects: 3, cookies: {})
        redirects = 0
        loop do
          validate_url!(url)
          uri = URI.parse(url)
          http = Net::HTTP.new(uri.host, uri.port)
          http.use_ssl = true
          http.verify_mode = ssl_insecure ? OpenSSL::SSL::VERIFY_NONE : OpenSSL::SSL::VERIFY_PEER
          http.open_timeout = open_timeout_sec
          http.read_timeout = read_timeout_sec

          request = build_request(method, uri, body, headers, cookies)
          response = http.request(request)
          merge_cookies!(cookies, uri.host, response)

          if response.is_a?(Net::HTTPRedirection) && response['location'] && redirects < max_redirects
            url = absolute_redirect(uri, response['location'])
            method = :get
            body = nil
            redirects += 1
            next
          end

          return response
        end
      end

      def build_request(method, uri, body, headers, cookies)
        request =
          case method
          when :post then Net::HTTP::Post.new(uri)
          else Net::HTTP::Get.new(uri)
          end
        headers.each { |k, v| request[k] = v }
        request.body = body if body
        host_jar = cookies[uri.host]
        request['Cookie'] = host_jar.map { |k, v| "#{k}=#{v}" }.join('; ') if host_jar && !host_jar.empty?
        request
      end

      def merge_cookies!(cookies, host, response)
        jar = (cookies[host] ||= {})
        Array(response.get_fields('set-cookie')).each do |raw|
          pair = raw.split(';', 2).first.to_s.split('=', 2)
          jar[pair[0].strip] = pair[1] if pair.length == 2
        end
      end

      def absolute_redirect(uri, location)
        URI.join(uri, location).to_s
      end
    end
  end
end
