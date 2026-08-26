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

require 'securerandom'
require 'active_record'
require 'aws-sdk-secretsmanager'
require_relative 'integration_helper'
require_relative 'utils/test_environment'
require_relative 'utils/test_environment_features'
require_relative 'utils/test_driver'
require_relative 'utils/driver_helper'
require_relative 'utils/connection_utils'
require 'aws_ruby_driver_wrapper'
require 'aws_ruby_driver_wrapper/active_record/aws_mysql2_adapter'
require 'aws_ruby_driver_wrapper/active_record/aws_postgresql_adapter'

# ActiveRecord smoke tests for the IAM and Secrets Manager plugins.
#
# The raw-driver iam_auth_spec.rb and secrets_manager_spec.rb own the auth mechanics (token caching,
# secret rotation, retry, dedup). The AR adapters contain no IAM or Secrets Manager specific code, so
# duplicating those mechanics here would add no coverage. What these tests do prove is the one seam
# that is genuinely AR-specific: that AR-style config keys reach the auth plugins intact.
#
# ActiveRecord configs use :username and :database, while the PG gem expects :user and :dbname.
# AwsPostgreSQLAdapter remaps them via AR_TO_PG_KEY_MAP; AwsMysql2Adapter does not remap, because the
# mysql2 dialect's user_property_key is already :username. Both plugins depend on that key landing
# where the dialect expects it:
#   * IamAuthPlugin requires a non-empty user, or it raises IamAuthError outright.
#   * SecretsManagerPlugin overwrites driver_props[driver_dialect.user_property_key] with the secret's
#     username, so a mismatched key would leave AR's original :username in place and silently ignore
#     the fetched credentials.
# A raw-driver test cannot catch a regression here because it never passes AR key names.
RSpec.describe 'Auth plugins (ActiveRecord)', :integration,
               disable_on_features: [Integration::TestEnvironmentFeatures::PERFORMANCE] do
  # Base AR connection config. Wrapper property keys pass through the adapter into the wrapper
  # unchanged; :username and :database are the AR-shaped keys whose translation we are exercising.
  def ar_config(username:, password:, plugin_props:)
    adapter = case drv
              when Integration::TestDriver::PG    then 'aws_postgresql'
              when Integration::TestDriver::MYSQL then 'aws_mysql2'
              else raise "Unsupported driver: #{drv}"
              end

    config = {
      adapter: adapter,
      host: writer.host,
      port: writer.port,
      username: username,
      password: password,
      database: info.default_dbname,
      connect_timeout: 10
    }

    # Both plugins authenticate over the wire, so TLS is required.
    case drv
    when Integration::TestDriver::PG    then config[:sslmode] = 'require'
    when Integration::TestDriver::MYSQL then config[:ssl_mode] = :required
    end

    config.merge(plugin_props)
  end

  def establish_and_select_one(config)
    ActiveRecord::Base.connection_handler.clear_all_connections!
    ActiveRecord::Base.establish_connection(config)
    ActiveRecord::Base.connection.select_value('SELECT 1').to_i
  end

  after do
    ActiveRecord::Base.connection_handler.clear_all_connections!
  end

  describe 'IAM authentication', features: [Integration::TestEnvironmentFeatures::IAM] do
    before do
      skip 'No allowed drivers for this environment' if drv.nil?
      begin
        AwsRubyDriverWrapper::Plugins::IamAuthPlugin.clear_cache(
          AwsRubyDriverWrapper::Services::CoreServices.storage_service
        )
      rescue StandardError
        nil
      end
    end

    it 'connects with an IAM token generated from the ActiveRecord username' do
      # The password is ignored: the IAM plugin replaces it with a generated token. If AR's :username
      # did not reach the plugin under the key it reads, this would raise IamAuthError instead.
      config = ar_config(username: env.iam_user_name, password: 'anything', plugin_props: base_iam_props)

      expect(establish_and_select_one(config)).to eq(1)
    end
  end

  describe 'Secrets Manager authentication', features: [Integration::TestEnvironmentFeatures::SECRETS_MANAGER] do
    before(:all) do
      @env = Integration::TestEnvironment.current
      @sm_client = Aws::SecretsManager::Client.new(region: @env.aurora_region)
      @secret_id = "aws-ruby-wrapper-it-ar-sm-#{SecureRandom.uuid}"
      @sm_client.create_secret(
        name: @secret_id,
        secret_string: JSON.generate(
          username: @env.database_info.username,
          password: @env.database_info.password
        )
      )
    end

    after(:all) do
      @sm_client&.delete_secret(secret_id: @secret_id, force_delete_without_recovery: true)
    rescue StandardError => e
      warn "Failed to delete test secret #{@secret_id}: #{e.message}"
    ensure
      @sm_client = nil
    end

    before do
      skip 'No allowed drivers for this environment' if drv.nil?
      begin
        AwsRubyDriverWrapper.clear_caches
      rescue StandardError
        nil
      end
    end

    it 'connects with credentials fetched from the secret, overriding the ActiveRecord credentials' do
      sm_props = {
        AwsRubyDriverWrapper::PropertyDefinition::PLUGINS.name => 'secrets_manager',
        AwsRubyDriverWrapper::PropertyDefinition::SECRET_ID.name => @secret_id,
        AwsRubyDriverWrapper::PropertyDefinition::SECRET_REGION.name => env.aurora_region,
        AwsRubyDriverWrapper::PropertyDefinition::CLUSTER_ID.name => env.cluster_name
      }
      # Deliberately wrong AR credentials: connecting proves the plugin's fetched username and password
      # replaced them under the key the dialect reads, rather than AR's values being used.
      config = ar_config(username: 'decoy_user', password: 'decoy_password', plugin_props: sm_props)

      expect(establish_and_select_one(config)).to eq(1)
    end
  end
end
