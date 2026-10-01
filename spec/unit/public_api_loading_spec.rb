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

require_relative '../spec_helper'
require 'open3'
require 'rbconfig'

# The public API must be reachable with nothing but `require 'aws_advanced_ruby_driver_wrapper'`, which is
# all Bundler.require does in a Rails app, so that it can be used before any connection is opened (in an
# initializer, a setup script, or a class body). The spec_helper has already loaded the driver files in
# this process, so the checks run in a fresh Ruby process.
RSpec.describe 'Public API loading' do
  lib_dir = File.expand_path('../../lib', __dir__)

  public_constants = %w[
    Errors::AwsError
    Errors::FailoverFailedError
    Errors::FailoverSuccessError
    Errors::TransactionStateUnknownError
    Errors::IamAuthError
    Errors::SecretsManagerAuthError
    Errors::PluginConflictError
    Errors::BlueGreenTimeoutError
    Errors::BlueGreenSwitchoverError
    Errors::EncryptionPluginError
    Errors::EncryptionError
    Errors::KeyManagementError
    Errors::MetadataError
    Host::HostAvailability
    Services::HostService
    Services::PluginManager
    Plugins::Encryption::EncryptionConfig
    Plugins::Encryption::KeyManagementUtility
  ].freeze

  # Runs +script+ in a new Ruby process after requiring only the gem's main file.
  def run_after_bare_require(lib_dir, script)
    Open3.capture2e(RbConfig.ruby, '-I', lib_dir, '-e', "require 'aws_advanced_ruby_driver_wrapper'\n#{script}")
  end

  it 'resolves every public constant' do
    script = <<~RUBY
      missing = #{public_constants.inspect}.reject do |name|
        AwsAdvancedRubyDriverWrapper.const_get(name)
      rescue NameError
        false
      end
      puts missing.join(',')
    RUBY
    output, status = run_after_bare_require(lib_dir, script)

    expect(status).to be_success, output
    expect(output.strip).to eq('')
  end

  it 'loads the kms_encryption errors into the AwsError hierarchy' do
    output, status = run_after_bare_require(lib_dir, <<~RUBY)
      errors = AwsAdvancedRubyDriverWrapper::Errors
      puts [errors::EncryptionError, errors::KeyManagementError, errors::MetadataError].all? { |e| e < errors::AwsError }
    RUBY

    expect(status).to be_success, output
    expect(output.strip).to eq('true')
  end

  it 'does not load a driver or AWS SDK gem when the autoloaded constants are referenced' do
    output, status = run_after_bare_require(lib_dir, <<~RUBY)
      %w[Services::HostService Services::PluginManager Plugins::Encryption::EncryptionConfig
         Plugins::Encryption::KeyManagementUtility]
        .each { |name| AwsAdvancedRubyDriverWrapper.const_get(name) }
      puts [defined?(PG::Connection), defined?(Mysql2::Client), defined?(Aws::KMS::Client), defined?(PgQuery)].compact.join(',')
    RUBY

    expect(status).to be_success, output
    expect(output.strip).to eq('')
  end
end
