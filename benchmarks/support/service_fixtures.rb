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

require 'aws_advanced_ruby_driver_wrapper/services/service_container'
require 'aws_advanced_ruby_driver_wrapper/services/connection_service'
require 'aws_advanced_ruby_driver_wrapper/services/host_service'
require 'aws_advanced_ruby_driver_wrapper/services/session_state_service'
require 'aws_advanced_ruby_driver_wrapper/services/plugin_manager'
require 'aws_advanced_ruby_driver_wrapper/utils/connection_config'
require 'aws_advanced_ruby_driver_wrapper/utils/storage/storage_service'
require 'aws_advanced_ruby_driver_wrapper/errors/pg_error_handler'
require 'aws_advanced_ruby_driver_wrapper/host/host_info'
require 'aws_advanced_ruby_driver_wrapper/host/host_role'
require_relative 'benchmark_services'

module AwsAdvancedRubyDriverWrapper
  module Benchmarks
    # Wires up the real services that carry the per-call hot paths the service benchmark
    # measures: {Services::ConnectionService} (current connection and host), {Services::HostService}
    # (topology reads, host selection, availability writes), {Services::SessionStateService}
    # (transaction state), the PostgreSQL error handler (network-error classification), and a
    # {Services::PluginManager} (the thread-local call context).
    #
    # Only the pieces that would otherwise need a live database - dialect detection and the driver
    # connection - are replaced with the cheap stubs from {BenchmarkServices}, so every measured
    # method runs its production implementation rather than a stand-in.
    #
    # A {Fixtures} carries a real {Utils::Storage::StorageService}, which starts a background cleanup
    # thread; callers must invoke {Fixtures#shutdown} when done so the process can exit cleanly.
    module PluginServiceFixtures
      DOMAIN = '.XYZ.us-east-2.rds.amazonaws.com'
      HOST_COUNT = 5
      # The custom endpoint plugin's allow-list cache: name, and the shape of a registered entry.
      ALLOWED_BLOCKED_CACHE = :custom_endpoint_allowed_blocked
      ALLOWED_IDS = Set['instance-1', 'instance-2', 'instance-3'].freeze
      STUB_CONNECTION = BenchmarkServices::STUB_CONNECTION

      # Hands the same fixed topology back on every refresh, so the host list is populated through the
      # real refresh path without a live database.
      class StaticHostListProvider
        def initialize(hosts)
          @hosts = hosts
        end

        def refresh
          @hosts
        end

        def force_refresh(_verify_writer, _timeout_sec)
          @hosts
        end
      end

      # The wired services plus the resources that must be released on shutdown.
      Fixtures = Struct.new(
        :connection_service,
        :host_service,
        :session_state_service,
        :plugin_manager,
        :error_handler,
        :reader_host,
        :storage_service,
        keyword_init: true
      ) do
        def shutdown
          storage_service&.shutdown
        end
      end

      module_function

      # A five-host Aurora-style topology: one writer and four readers, each with an instance id.
      def topology
        hosts = [host('instance-0', Host::HostRole::WRITER)]
        (1...HOST_COUNT).each { |i| hosts << host("instance-#{i}", Host::HostRole::READER) }
        hosts
      end

      def host(id, role)
        Host::HostInfo.new(host: "#{id}#{DOMAIN}", port: '5432', role: role, id: id)
      end

      # @param with_allow_list [Boolean] when true, registers a custom-endpoint allow-list entry so
      #   {Services::HostService#hosts} runs its filtering path rather than returning the topology as-is
      # @return [Fixtures]
      def build(with_allow_list: false)
        hosts = topology
        writer = hosts.first

        storage_service = Utils::Storage::StorageService.new(event_publisher: nil)

        container = Services::ServiceContainer.new
        container.dialect_service = BenchmarkServices::StubDialectService.new
        container.storage_service = storage_service

        config = Utils::ConnectionConfig.new(initial_host_info: writer, driver_name: :postgresql)
        connection_service = Services::ConnectionService.new(container, config)
        container.connection_service = connection_service

        session_state_service = Services::SessionStateService.new
        container.session_state_service = session_state_service

        host_service = Services::HostService.new(container)
        host_service.host_list_provider = StaticHostListProvider.new(hosts)
        host_service.refresh_host_list
        container.host_service = host_service

        connection_service.update_current_connection(STUB_CONNECTION, writer)

        if with_allow_list
          storage_service.register(ALLOWED_BLOCKED_CACHE, ttl: 300)
          storage_service.set(
            ALLOWED_BLOCKED_CACHE,
            writer.url,
            { allowed: ALLOWED_IDS, blocked: nil, required_role: nil }
          )
        end

        # The call context lives on the calling thread, so any manager instance reads the same value;
        # a plugin-free manager is the cheapest one to construct.
        plugin_manager = Services::PluginManager.new(BenchmarkServices.container({ wrapper_plugins: '' }))

        error_handler = Errors::PgErrorHandler.new(container.dialect_service.driver_dialect)

        Fixtures.new(
          connection_service: connection_service,
          host_service: host_service,
          session_state_service: session_state_service,
          plugin_manager: plugin_manager,
          error_handler: error_handler,
          reader_host: hosts[1],
          storage_service: storage_service
        )
      end
    end
  end
end
