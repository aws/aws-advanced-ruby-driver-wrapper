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

require_relative 'aws_ruby_database_driver_wrapper/version'
require_relative 'aws_ruby_database_driver_wrapper/custom_configuration'
require_relative 'aws_ruby_database_driver_wrapper/property_definition'
require_relative 'aws_ruby_database_driver_wrapper/logging'
require_relative 'aws_ruby_database_driver_wrapper/utils/rds_utils'
require_relative 'aws_ruby_database_driver_wrapper/utils/connection_config'
require_relative 'aws_ruby_database_driver_wrapper/utils/connection_config_parser'
require_relative 'aws_ruby_database_driver_wrapper/monitoring/monitor_state'
require_relative 'aws_ruby_database_driver_wrapper/monitoring/monitor'
require_relative 'aws_ruby_database_driver_wrapper/services/shutdown_service'

module AwsRubyDatabaseDriverWrapper
  @config = Configuration.new

  class << self
    attr_reader :config
  end

  def self.shutdown_service
    @shutdown_service ||= Services::ShutdownService.instance
  end

  def self.shutdown(grace_period_sec: 10)
    shutdown_service.shutdown(grace_period_sec)
  end

  def self.clear_caches
    require_relative 'aws_ruby_database_driver_wrapper/services/service_utility'
    require_relative 'aws_ruby_database_driver_wrapper/services/host_id_cache_service'
    Services::CoreServices.storage_service.clear_all
    Utils::RdsUtils.clear_cache
    Services::DialectService.known_endpoint_dialects.clear
    Services::HostIdCacheService.clear_cache
  end

  def self.release_resources
    require_relative 'aws_ruby_database_driver_wrapper/services/service_utility'
    Services::CoreServices.monitor_service.shutdown(grace_period: 5)
    Services::CoreServices.event_publisher.release_resources
    clear_caches
  end
end

# Register signal traps and at_exit hook for graceful shutdown.
%w[TERM INT].each do |signal|
  trap(signal) do
    AwsRubyDatabaseDriverWrapper.shutdown
    exit(0)
  end
end

at_exit { AwsRubyDatabaseDriverWrapper.shutdown }

# Register adapters with ActiveRecord if it is loaded.
# The register call is lazy — the adapter file is only loaded when a connection is first established.
# Users will not load the code for both adapters if they are only using one of them.
if defined?(ActiveRecord::ConnectionAdapters) && ActiveRecord::ConnectionAdapters.respond_to?(:register)
  ActiveRecord::ConnectionAdapters.register(
    'aws_postgresql',
    'ActiveRecord::ConnectionAdapters::AwsPostgreSQLAdapter',
    'aws_ruby_database_driver_wrapper/active_record/aws_postgresql_adapter'
  )

  ActiveRecord::ConnectionAdapters.register(
    'aws_mysql2',
    'ActiveRecord::ConnectionAdapters::AwsMysql2Adapter',
    'aws_ruby_database_driver_wrapper/active_record/aws_mysql2_adapter'
  )
end
