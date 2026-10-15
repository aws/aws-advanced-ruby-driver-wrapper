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

require_relative '../../../spec_helper'
require 'net/http'
require 'aws-sdk-rds'
require 'aws_advanced_ruby_driver_wrapper/plugins/federated_auth/federated_auth_plugin'
require 'aws_advanced_ruby_driver_wrapper/utils/saml_utils'
require 'aws_advanced_ruby_driver_wrapper/errors'

RSpec.describe AwsAdvancedRubyDriverWrapper::Plugins::FederatedAuth::FederatedAuthPlugin do
  SamlUtils = AwsAdvancedRubyDriverWrapper::Utils::SamlUtils
  SamlAuthError = AwsAdvancedRubyDriverWrapper::Errors::SamlAuthError

  # A stand-in Net::HTTPResponse: real enough for the `is_a?(Net::HTTPSuccess)`
  # check the plugin performs, without an actual HTTP round-trip.
  class FakeHttpResponse
    attr_reader :body, :code, :message

    def initialize(body: '', code: '200', message: 'OK', success: true)
      @body = body
      @code = code
      @message = message
      @success = success
    end

    def is_a?(klass)
      return @success if klass == Net::HTTPSuccess

      super
    end
  end

  ADFS_ENDPOINT = 'ec2amaz-ab3cdef.example.com'
  ADFS_PORT = 443
  RP_IDENTIFIER = 'urn:amazon:webservices'

  SIGN_ON_URL =
    "https://#{ADFS_ENDPOINT}:#{ADFS_PORT}/adfs/ls/IdpInitiatedSignOn.aspx?loginToRp=#{RP_IDENTIFIER}".freeze

  # A sign-on page with the fields AD FS actually posts back: a form action, the
  # username and password inputs, an AuthMethod hidden field, and an opaque
  # hidden field that must be carried through untouched.
  SIGN_ON_PAGE = <<~HTML
    <html><body>
      <form method="post" action="/adfs/ls/?client-request-id=abc&amp;foo=bar">
        <input name="UserName" type="email" value="" />
        <input name="Password" type="password" value="" />
        <input name="AuthMethod" type="hidden" value="FormsAuthentication" />
        <input name="Kmsi" type="hidden" value="true" />
      </form>
    </body></html>
  HTML

  SAML_RESPONSE_PAGE = <<~HTML
    <html><body>
      <form method="post" action="https://signin.aws.amazon.com/saml">
        <input type="hidden" name="SAMLResponse" value="BASE64ASSERTION==" />
      </form>
    </body></html>
  HTML

  def fetch_options(overrides = {})
    {
      idp_endpoint: ADFS_ENDPOINT,
      idp_port: ADFS_PORT,
      idp_username: 'jimbob@example.com',
      idp_password: 'idpSecret',
      rp_identifier: RP_IDENTIFIER,
      ssl_insecure: false,
      socket_timeout_sec: 60.0,
      connect_timeout_sec: 60.0
    }.merge(overrides)
  end

  describe '.fetch_saml_assertion' do
    it 'GETs the sign-on page, POSTs the form, and returns the extracted assertion' do
      allow(SamlUtils).to receive(:http_request) do |method:, url:, **_rest|
        if method == :get
          expect(url).to eq(SIGN_ON_URL)
          FakeHttpResponse.new(body: SIGN_ON_PAGE)
        else
          FakeHttpResponse.new(body: SAML_RESPONSE_PAGE)
        end
      end

      assertion = described_class.fetch_saml_assertion(**fetch_options)

      expect(assertion).to eq('BASE64ASSERTION==')
    end

    it 'POSTs to the absolute URL built from the form action and the federated credentials' do
      posted = {}
      allow(SamlUtils).to receive(:http_request) do |method:, url:, body: nil, **_rest|
        if method == :get
          FakeHttpResponse.new(body: SIGN_ON_PAGE)
        else
          posted[:url] = url
          posted[:body] = body
          FakeHttpResponse.new(body: SAML_RESPONSE_PAGE)
        end
      end

      described_class.fetch_saml_assertion(**fetch_options)

      expect(posted[:url]).to eq("https://#{ADFS_ENDPOINT}:#{ADFS_PORT}/adfs/ls/?client-request-id=abc&foo=bar")
      params = URI.decode_www_form(posted[:body]).to_h
      expect(params['UserName']).to eq('jimbob@example.com')
      expect(params['Password']).to eq('idpSecret')
      expect(params['AuthMethod']).to eq('FormsAuthentication')
      expect(params['Kmsi']).to eq('true')
    end

    it 'raises SamlAuthError when the sign-on page request fails' do
      allow(SamlUtils).to receive(:http_request)
        .and_return(FakeHttpResponse.new(code: '500', message: 'Server Error', success: false))

      expect { described_class.fetch_saml_assertion(**fetch_options) }
        .to raise_error(SamlAuthError, /sign-on page.*500/)
    end

    it 'raises SamlAuthError with a diagnostic hint when the POST response carries no SAML assertion' do
      allow(SamlUtils).to receive(:http_request) do |method:, **_rest|
        FakeHttpResponse.new(body: method == :get ? SIGN_ON_PAGE : '<html>no assertion here</html>')
      end

      expect { described_class.fetch_saml_assertion(**fetch_options) }
        .to raise_error(SamlAuthError, /no SAML assertion.*check idp_username, idp_password, and idp_endpoint/)
    end

    it 'does not include the response body in the no-assertion error' do
      secret_markup = '<html>SENSITIVE-ERROR-DETail-xyz</html>'
      allow(SamlUtils).to receive(:http_request) do |method:, **_rest|
        FakeHttpResponse.new(body: method == :get ? SIGN_ON_PAGE : secret_markup)
      end

      expect { described_class.fetch_saml_assertion(**fetch_options) }
        .to raise_error(SamlAuthError) { |e| expect(e.message).not_to include('SENSITIVE-ERROR-DETail') }
    end
  end

  describe '.form_parameters' do
    let(:body) { SIGN_ON_PAGE }

    it 'substitutes the username and password inputs with the federated credentials' do
      params = described_class.form_parameters(body, 'user@corp', 'secretpw').to_h
      expect(params['UserName']).to eq('user@corp')
      expect(params['Password']).to eq('secretpw')
    end

    it 'preserves the AuthMethod and other hidden fields' do
      params = described_class.form_parameters(body, 'u', 'p').to_h
      expect(params['AuthMethod']).to eq('FormsAuthentication')
      expect(params['Kmsi']).to eq('true')
    end

    it 'drops an AuthMethod field with an empty value' do
      html = '<input name="AuthMethod" type="hidden" value="" />'
      names = described_class.form_parameters(html, 'u', 'p').map(&:first)
      expect(names).not_to include('AuthMethod')
    end

    it 'skips inputs with no name attribute' do
      html = '<input type="hidden" value="orphan" />'
      expect(described_class.form_parameters(html, 'u', 'p')).to be_empty
    end

    it 'de-duplicates inputs case-insensitively by name, keeping the first' do
      html = '<input name="Token" value="first" /><input name="token" value="second" />'
      params = described_class.form_parameters(html, 'u', 'p')
      expect(params).to eq([%w[Token first]])
    end
  end

  describe '.form_action' do
    it 'extracts and HTML-unescapes the form action' do
      expect(described_class.form_action(SIGN_ON_PAGE)).to eq('/adfs/ls/?client-request-id=abc&foo=bar')
    end

    it 'returns nil when there is no form' do
      expect(described_class.form_action('<html>no form</html>')).to be_nil
    end
  end

  describe '.unescape_html' do
    it 'unescapes the standard XML entities' do
      expect(described_class.unescape_html('a&amp;b&lt;c&gt;d&quot;e&apos;f')).to eq(%(a&b<c>d"e'f))
    end
  end

  describe '.require_body!' do
    it 'returns the body for a successful response' do
      expect(described_class.require_body!(FakeHttpResponse.new(body: 'ok'), 'thing')).to eq('ok')
    end

    it 'raises SamlAuthError describing the failing request' do
      resp = FakeHttpResponse.new(code: '403', message: 'Forbidden', success: false)
      expect { described_class.require_body!(resp, 'sign-on POST') }
        .to raise_error(SamlAuthError, /sign-on POST.*403 Forbidden/)
    end
  end

  describe 'PluginManager registration' do
    before { require 'aws_advanced_ruby_driver_wrapper/services/plugin_manager' }

    it "is registered under the code 'federated_auth'" do
      plugin_classes = AwsAdvancedRubyDriverWrapper::Services::PluginManager.plugin_classes
      expect(plugin_classes['federated_auth']).to eq(described_class)
    end

    it 'cannot be combined with another authentication plugin' do
      wrapper_props = Concurrent::Map.new
      wrapper_props[:wrapper_plugins] = 'federated_auth,iam'
      connection_service = double('ConnectionService', wrapper_props:)
      container = double('ServiceContainer', connection_service:)

      expect do
        AwsAdvancedRubyDriverWrapper::Services::PluginManager.new(container)
      end.to raise_error(AwsAdvancedRubyDriverWrapper::Errors::PluginConflictError)
    end
  end

  describe 'default idp_name' do
    it 'defaults the identity provider name to adfs' do
      expect(
        AwsAdvancedRubyDriverWrapper::PropertyDefinition::IDP_NAME.get(Concurrent::Map.new)
      ).to eq('adfs')
    end
  end
end
