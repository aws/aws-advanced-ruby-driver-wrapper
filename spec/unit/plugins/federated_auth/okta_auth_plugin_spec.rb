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

# ----------------------------------------------------------------------------
# Specs for the Okta-specific half of OktaAuthPlugin.
#
# The shared SAML connect flow (caching, STS exchange, token minting, retry,
# validation) is covered once against the base in base_saml_auth_plugin_spec.rb.
# This file covers what is unique to Okta: authenticating to Okta's /authn API
# for a one-time session token, redeeming it at the AWS app's SSO SAML endpoint,
# and extracting the assertion - i.e. `.fetch_saml_assertion` and `.session_token`
# - plus the two config seams Okta overrides (app_id is required, and app_id is
# threaded into the IdP flow). SamlUtils.http_request is stubbed so no network
# call happens.
# ----------------------------------------------------------------------------

require_relative '../../../spec_helper'
require 'net/http'
require 'aws-sdk-rds'
require 'aws_advanced_ruby_driver_wrapper/plugins/federated_auth/okta_auth_plugin'
require 'aws_advanced_ruby_driver_wrapper/host/host_info'
require 'aws_advanced_ruby_driver_wrapper/utils/iam_auth_utils'
require 'aws_advanced_ruby_driver_wrapper/utils/saml_utils'
require 'aws_advanced_ruby_driver_wrapper/errors'

RSpec.describe AwsAdvancedRubyDriverWrapper::Plugins::FederatedAuth::OktaAuthPlugin do
  OKTA_SAML_UTILS = AwsAdvancedRubyDriverWrapper::Utils::SamlUtils
  OKTA_SAML_ERROR = AwsAdvancedRubyDriverWrapper::Errors::SamlAuthError

  # A stand-in Net::HTTPResponse: real enough for the `is_a?(Net::HTTPSuccess)`
  # check the plugin performs, without an actual HTTP round-trip.
  class OktaFakeHttpResponse
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

  OKTA_ENDPOINT = 'example.okta.com'
  OKTA_APP_ID = 'okta-aws-app-id'
  OKTA_SESSION_TOKEN = 'one-time-session-token'

  AUTHN_URL = "https://#{OKTA_ENDPOINT}/api/v1/authn".freeze
  SAML_URL =
    "https://#{OKTA_ENDPOINT}/app/amazon_aws/#{OKTA_APP_ID}/sso/saml?onetimetoken=#{OKTA_SESSION_TOKEN}".freeze

  SAML_PAGE = <<~HTML
    <html><body>
      <form method="post" action="https://signin.aws.amazon.com/saml">
        <input type="hidden" name="SAMLResponse" value="BASE64&#x2b;ASSERTION&#x3d;&#x3d;" />
      </form>
    </body></html>
  HTML

  def fetch_options(overrides = {})
    {
      idp_endpoint: OKTA_ENDPOINT,
      app_id: OKTA_APP_ID,
      idp_username: 'jimbob@example.com',
      idp_password: 'idpSecret',
      ssl_insecure: false,
      socket_timeout_sec: 60.0,
      connect_timeout_sec: 60.0
    }.merge(overrides)
  end

  def authn_response(token: OKTA_SESSION_TOKEN)
    OktaFakeHttpResponse.new(body: JSON.generate(sessionToken: token))
  end

  describe '.fetch_saml_assertion' do
    it 'authenticates for a session token, redeems it at the SSO SAML endpoint, and extracts the assertion' do
      requests = []
      allow(OKTA_SAML_UTILS).to receive(:http_request) do |method:, url:, body: nil, **_rest|
        requests << { method:, url:, body: }
        url == AUTHN_URL ? authn_response : OktaFakeHttpResponse.new(body: SAML_PAGE)
      end

      assertion = described_class.fetch_saml_assertion(**fetch_options)

      expect(assertion).to eq('BASE64+ASSERTION==')
      authn = requests.find { |r| r[:url] == AUTHN_URL }
      expect(authn[:method]).to eq(:post)
      expect(JSON.parse(authn[:body])).to eq('username' => 'jimbob@example.com', 'password' => 'idpSecret')
      expect(requests.map { |r| r[:url] }).to include(SAML_URL)
    end

    it 'raises SamlAuthError when the SSO SAML request fails' do
      allow(OKTA_SAML_UTILS).to receive(:http_request) do |url:, **_rest|
        url == AUTHN_URL ? authn_response : OktaFakeHttpResponse.new(code: '502', message: 'Bad Gateway', success: false)
      end

      expect { described_class.fetch_saml_assertion(**fetch_options) }
        .to raise_error(OKTA_SAML_ERROR, /SAML request failed.*502/)
    end

    it 'raises SamlAuthError when the SAML response has no SAMLResponse input' do
      allow(OKTA_SAML_UTILS).to receive(:http_request) do |url:, **_rest|
        url == AUTHN_URL ? authn_response : OktaFakeHttpResponse.new(body: '<html>no assertion</html>')
      end

      expect { described_class.fetch_saml_assertion(**fetch_options) }
        .to raise_error(OKTA_SAML_ERROR, /invalid SAML response/)
    end
  end

  describe '.session_token' do
    let(:http) do
      lambda do |method, url, body: nil, headers: {}|
        OKTA_SAML_UTILS.http_request(method:, url:, body:, headers:, ssl_insecure: false,
                                     open_timeout_sec: 1, read_timeout_sec: 1)
      end
    end

    it 'returns the sessionToken from the /authn JSON response' do
      allow(OKTA_SAML_UTILS).to receive(:http_request).and_return(authn_response(token: 'tok-123'))

      token = described_class.session_token(http, OKTA_ENDPOINT, 'user', 'pw')

      expect(token).to eq('tok-123')
    end

    it 'raises SamlAuthError when the /authn request fails' do
      allow(OKTA_SAML_UTILS).to receive(:http_request)
        .and_return(OktaFakeHttpResponse.new(code: '401', message: 'Unauthorized', success: false))

      expect { described_class.session_token(http, OKTA_ENDPOINT, 'user', 'pw') }
        .to raise_error(OKTA_SAML_ERROR, /session token request failed.*401/)
    end

    it 'raises SamlAuthError when the response carries no session token, surfacing the Okta status' do
      allow(OKTA_SAML_UTILS).to receive(:http_request)
        .and_return(OktaFakeHttpResponse.new(body: JSON.generate(status: 'MFA_REQUIRED')))

      expect { described_class.session_token(http, OKTA_ENDPOINT, 'user', 'pw') }
        .to raise_error(OKTA_SAML_ERROR, /did not return a session token \(status: MFA_REQUIRED\)/)
    end

    it 'raises SamlAuthError when the response body is not valid JSON' do
      allow(OKTA_SAML_UTILS).to receive(:http_request)
        .and_return(OktaFakeHttpResponse.new(body: 'not json'))

      expect { described_class.session_token(http, OKTA_ENDPOINT, 'user', 'pw') }
        .to raise_error(OKTA_SAML_ERROR, /did not return a session token/)
    end
  end

  # Okta-specific config seams, verified through a real connect so that app_id is
  # shown to flow from wrapper_props into validation and into the IdP fetch.
  describe 'app_id configuration' do
    let(:mock_storage_service) { instance_double(AwsAdvancedRubyDriverWrapper::Utils::Storage::StorageService) }
    let(:mock_db_dialect) { double('DbDialect', default_port: 5432) }
    let(:mock_driver_dialect) { double('DriverDialect', user_property_key: :user) }
    let(:mock_dialect_service) do
      double('DialectService', db_dialect: mock_db_dialect, login_error?: false, driver_dialect: mock_driver_dialect)
    end
    let(:mock_service_container) do
      double('ServiceContainer', storage_service: mock_storage_service, dialect_service: mock_dialect_service)
    end

    def wrapper_props_map(hash)
      map = Concurrent::Map.new
      hash.each { |k, v| map[k] = v }
      map
    end

    def base_props
      {
        db_user: 'iamUser',
        idp_endpoint: OKTA_ENDPOINT,
        app_id: OKTA_APP_ID,
        iam_role_arn: 'arn:aws:iam::123456789012:role/example_iam_role',
        iam_idp_arn: 'arn:aws:iam::123456789012:saml-provider/example',
        iam_region: 'us-east-2'
      }
    end

    def build_plugin(overrides = {})
      described_class.new(mock_service_container, wrapper_props_map(base_props.merge(overrides)))
    end

    def pg_host_info
      AwsAdvancedRubyDriverWrapper::Host::HostInfo.new(
        host: 'pg.testdb.us-east-2.rds.amazonaws.com',
        port: AwsAdvancedRubyDriverWrapper::Host::HostInfo::NO_PORT
      )
    end

    before do
      allow(mock_storage_service).to receive(:register)
      allow(mock_storage_service).to receive(:get).and_return(nil)
      allow(mock_storage_service).to receive(:set)
      allow(described_class).to receive(:credentials_from_saml).and_return(Aws::Credentials.new('AKID', 'SECRET'))
      allow(Aws::RDS::AuthTokenGenerator).to receive(:new)
        .and_return(instance_double(Aws::RDS::AuthTokenGenerator, auth_token: 'token'))
    end

    it 'raises SamlAuthError when app_id is missing' do
      expect do
        build_plugin(app_id: nil).connect(pg_host_info, {}, true, -> {})
      end.to raise_error(OKTA_SAML_ERROR, /app_id/)
    end

    it 'threads app_id from wrapper_props into the SAML assertion fetch' do
      captured_app_id = nil
      allow(described_class).to receive(:fetch_saml_assertion) do |app_id:, **_rest|
        captured_app_id = app_id
        'fake-assertion'
      end

      begin
        build_plugin.connect(pg_host_info, {}, true, -> { raise StandardError, 'simulated' })
      rescue StandardError
        nil
      end

      expect(captured_app_id).to eq(OKTA_APP_ID)
    end
  end

  describe 'PluginManager registration' do
    before { require 'aws_advanced_ruby_driver_wrapper/services/plugin_manager' }

    it "is registered under the code 'okta'" do
      plugin_classes = AwsAdvancedRubyDriverWrapper::Services::PluginManager.plugin_classes
      expect(plugin_classes['okta']).to eq(described_class)
    end

    it 'cannot be combined with another authentication plugin' do
      wrapper_props = Concurrent::Map.new
      wrapper_props[:wrapper_plugins] = 'okta,iam'
      connection_service = double('ConnectionService', wrapper_props:)
      container = double('ServiceContainer', connection_service:)

      expect do
        AwsAdvancedRubyDriverWrapper::Services::PluginManager.new(container)
      end.to raise_error(AwsAdvancedRubyDriverWrapper::Errors::PluginConflictError)
    end
  end
end
