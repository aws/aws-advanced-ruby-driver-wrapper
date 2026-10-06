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

require_relative 'aws_advanced_ruby_driver_wrapper/version'
require_relative 'aws_advanced_ruby_driver_wrapper/custom_configuration'
require_relative 'aws_advanced_ruby_driver_wrapper/property_definition'
require_relative 'aws_advanced_ruby_driver_wrapper/logging'
# Error classes are loaded up front so they can be named before any connection is opened, for
# example in a Rails `rescue_from` or ActiveJob `retry_on`, which are evaluated at class load.
require_relative 'aws_advanced_ruby_driver_wrapper/errors'
require_relative 'aws_advanced_ruby_driver_wrapper/plugins/kms_encryption/errors'
require_relative 'aws_advanced_ruby_driver_wrapper/utils/rds_utils'
require_relative 'aws_advanced_ruby_driver_wrapper/utils/connection_config'
require_relative 'aws_advanced_ruby_driver_wrapper/utils/connection_config_parser'
require_relative 'aws_advanced_ruby_driver_wrapper/monitoring/monitor_state'
require_relative 'aws_advanced_ruby_driver_wrapper/monitoring/monitor'
require_relative 'aws_advanced_ruby_driver_wrapper/plugins/blue_green/blue_green_plugin'

module AwsAdvancedRubyDriverWrapper
  @config = Configuration.new

  # Direct-driver connection classes are autoloaded so requiring this file alone is enough to use them:
  # referencing either constant loads its driver-specific file on demand. Loading stays lazy - a client
  # for one driver never loads the other driver's code, and the underlying 'pg'/'mysql2' gem is only
  # required when a connection is actually opened.
  autoload :WrapperPgConnection, 'aws_advanced_ruby_driver_wrapper/postgresql'
  autoload :WrapperMysql2Client, 'aws_advanced_ruby_driver_wrapper/mysql'

  # Other public entry points are autoloaded for the same reason, so they work from code that runs
  # before any connection is opened, such as a Rails initializer or a setup script.
  module Services
    autoload :HostService, 'aws_advanced_ruby_driver_wrapper/services/host_service'
    autoload :PluginManager, 'aws_advanced_ruby_driver_wrapper/services/plugin_manager'
  end

  module Plugins
    module Encryption
      autoload :EncryptionConfig, 'aws_advanced_ruby_driver_wrapper/plugins/kms_encryption/encryption_config'
      autoload :KeyManagementUtility, 'aws_advanced_ruby_driver_wrapper/plugins/kms_encryption/key_management_utility'
    end
  end

  class << self
    attr_reader :config
  end

  # Gracefully tears down all background resources. Invoked by the at_exit hook (and thus
  # indirectly by the TERM/INT signal traps, which just exit). Safe to call more than once.
  def self.shutdown(grace_period_sec: 10)
    Plugins::BlueGreen::BlueGreenPlugin.clean_up_providers
    release_resources(grace_period_sec: grace_period_sec)
  end

  def self.clear_caches
    require_relative 'aws_advanced_ruby_driver_wrapper/services/service_utility'
    require_relative 'aws_advanced_ruby_driver_wrapper/services/host_service'
    Services::CoreServices.storage_service.clear_all
    Utils::RdsUtils.clear_cache
    Services::DialectService.known_endpoint_dialects.clear
    Services::HostService.clear_id_cache
  end

  def self.release_resources(grace_period_sec: 5)
    require_relative 'aws_advanced_ruby_driver_wrapper/services/service_utility'
    Services::CoreServices.monitor_service.shutdown(grace_period: grace_period_sec)
    Services::CoreServices.event_publisher.release_resources
    clear_caches
  end
end

# Register signal traps and at_exit hook for graceful shutdown. The traps only exit — the real
# teardown runs in the at_exit hook, since acquiring locks / joining threads inside a signal-trap
# context is unsafe in Ruby and can deadlock.
%w[TERM INT].each { |signal| trap(signal) { exit(0) } }

at_exit { AwsAdvancedRubyDriverWrapper.shutdown }

# Register adapters with ActiveRecord via a lazy-load hook so the require order between this file and
# ActiveRecord does not matter. The block runs the first time ActiveRecord::Base is referenced, whether
# ActiveRecord is loaded before or after this file. The register call is itself lazy — each adapter file
# is only loaded when a connection using that adapter is first established, so users of a single adapter
# never load the other.
begin
  require 'active_support/lazy_load_hooks'
rescue LoadError
  # ActiveSupport is absent (raw-driver-only usage with no ActiveRecord); there is nothing to register.
end

if defined?(ActiveSupport) && ActiveSupport.respond_to?(:on_load)
  ActiveSupport.on_load(:active_record) do
    require_relative 'aws_advanced_ruby_driver_wrapper/active_record/type_adapter_alias'

    ActiveRecord::ConnectionAdapters.register(
      'aws_postgresql',
      'ActiveRecord::ConnectionAdapters::AwsPostgreSQLAdapter',
      'aws_advanced_ruby_driver_wrapper/active_record/aws_postgresql_adapter'
    )

    ActiveRecord::ConnectionAdapters.register(
      'aws_mysql2',
      'ActiveRecord::ConnectionAdapters::AwsMysql2Adapter',
      'aws_advanced_ruby_driver_wrapper/active_record/aws_mysql2_adapter'
    )
  end
end

require_relative 'aws_advanced_ruby_driver_wrapper/active_record/type_adapter_alias' if defined?(ActiveRecord)
