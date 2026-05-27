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

require_relative 'service_container'
require_relative 'connection_service'
require_relative 'dialect_service'
require_relative 'host_service'
require_relative 'plugin_manager'
require_relative 'session_state_service'
require_relative 'monitor_service'
require_relative '../utils/storage/storage_service'

module AwsRubyDatabaseDriverWrapper
  module Services
    module ServiceUtility
      def self.create_standard_container(config)
        container = ServiceContainer.new
        container.connection_service = ConnectionService.new(container, config)
        container.dialect_service = DialectService.new(config.driver_name)
        container.host_service = HostService.new(container)
        container.session_state_service = SessionStateService.new
        container.storage_service = Utils::Storage::StorageService.shared_instance
        container.monitor_service = MonitorService.instance
        container.plugin_manager = PluginManager.new(container)
        container
      end

      def self.create_monitor_container(parent_container)
        container = ServiceContainer.new
        container.dialect_service = parent_container.dialect_service
        container.host_service = parent_container.host_service
        container
      end
    end
  end
end
