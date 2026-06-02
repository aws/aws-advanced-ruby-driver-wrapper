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
require_relative 'monitor_service'
require_relative 'session_state_service'
require_relative '../utils/storage/storage_service'
require_relative '../utils/events/batching_event_publisher'

module AwsRubyDatabaseDriverWrapper
  module Services
    # Manages shared singleton services with correct dependency order.
    # Initialized eagerly at require-time to avoid thread-safety races.
    module CoreServices
      @event_publisher = Utils::Events::BatchingEventPublisher.new
      @storage_service = Utils::Storage::StorageService.new(event_publisher: @event_publisher)
      @monitor_service = MonitorService.new(event_publisher: @event_publisher)

      class << self
        attr_reader :event_publisher, :storage_service, :monitor_service
      end

      # Resets all shared instances. For testing only.
      # @api private
      def self.reset!
        @monitor_service.shutdown(grace_period: 2)
        @storage_service.shutdown
        @event_publisher.release_resources
        @event_publisher = Utils::Events::BatchingEventPublisher.new
        @storage_service = Utils::Storage::StorageService.new(event_publisher: @event_publisher)
        @monitor_service = MonitorService.new(event_publisher: @event_publisher)
      end
    end

    module ServiceUtility
      def self.create_standard_container(config)
        container = ServiceContainer.new
        container.event_publisher = CoreServices.event_publisher
        container.connection_service = ConnectionService.new(container, config)
        container.dialect_service = DialectService.new(config.driver_name)
        container.dialect_service.get_dialect(container.connection_service)
        container.host_service = HostService.new(container)
        container.session_state_service = SessionStateService.new
        container.storage_service = CoreServices.storage_service
        container.monitor_service = CoreServices.monitor_service
        container.plugin_manager = PluginManager.new(container)
        container.dialect_service.setup_initial_provider(container)
        container
      end

      def self.create_monitor_container(parent_container)
        container = ServiceContainer.new
        container.event_publisher = parent_container.event_publisher
        container.dialect_service = parent_container.dialect_service
        container.host_service = parent_container.host_service
        container
      end
    end
  end
end
