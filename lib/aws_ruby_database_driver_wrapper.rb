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
require_relative 'aws_ruby_database_driver_wrapper/property_definition'
require_relative 'aws_ruby_database_driver_wrapper/logging'
require_relative 'aws_ruby_database_driver_wrapper/utils/rds_utils'
require_relative 'aws_ruby_database_driver_wrapper/utils/connection_config'
require_relative 'aws_ruby_database_driver_wrapper/utils/connection_config_parser'
require_relative 'aws_ruby_database_driver_wrapper/monitoring/monitor_state'
require_relative 'aws_ruby_database_driver_wrapper/monitoring/monitor'
require_relative 'aws_ruby_database_driver_wrapper/services/shutdown_service'

if defined?(ActiveRecord)
  if defined?(PG)
    require_relative 'aws_ruby_database_driver_wrapper/postgresql'
    require_relative 'aws_ruby_database_driver_wrapper/activerecord/aws_postgresql_adapter'
  end

  if defined?(Mysql2)
    require_relative 'aws_ruby_database_driver_wrapper/mysql'
    require_relative 'aws_ruby_database_driver_wrapper/activerecord/aws_mysql2_adapter'
  end
end

module AwsRubyDatabaseDriverWrapper
  # Clean up resources on SIGTERM.
  %w[TERM INT].each do |signal|
    trap(signal) do
      shutdown
      exit(0)
    end
  end

  # Clean up resources on process exit.
  at_exit do
    shutdown
  end

  def self.shutdown_service
    @shutdown_service ||= Services::ShutdownService.instance
  end

  def self.shutdown(grace_period_sec: 10)
    shutdown_service.shutdown(grace_period_sec)
  end
end
