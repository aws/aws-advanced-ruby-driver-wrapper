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

require 'aws_advanced_ruby_driver_wrapper/services/plugin_manager'
require 'aws_advanced_ruby_driver_wrapper/utils/storage/storage_service'
require_relative 'benchmark_services'
require_relative 'fake_mysql2_driver'

module AwsAdvancedRubyDriverWrapper
  module Benchmarks
    # Shared wiring for building a real plugin manager with a single wrapper plugin enabled, so both
    # the real-plugin-chain benchmark and its guard spec construct the managers the same way.
    #
    # The managers here reuse the constant-cost stub services, with two additions the real plugins
    # need that the plugin-free benchmarks do not:
    #   - a real StorageService, so the auth and endpoint plugins can register their caches at
    #     construction. Each one owns a background cleanup thread, so every service handed out is
    #     collected and must be shut down by the caller when the run ends.
    #   - the manager wired back onto its own container, so a plugin that reads the current call
    #     context (kms_encryption) can reach it from execute.
    module RealPluginChainSupport
      # A statement the execute pipeline carries so the plugins that inspect SQL do their real work.
      SQL = 'SELECT id, name FROM users WHERE id = 42'

      # The chains measured, in report order: a no-plugins baseline, one entry per wrapper plugin
      # code, and one combo of the plugins enabled by default. Keeping the code and its chain string
      # together means adding a plugin is a one-line change.
      CHAINS = {
        'no_plugins' => '',
        'bg' => 'bg',
        'custom_endpoint' => 'custom_endpoint',
        'failover' => 'failover',
        'gdb_failover' => 'gdb_failover',
        'iam' => 'iam',
        'initial_connection' => 'initial_connection',
        'kms_encryption' => 'kms_encryption',
        'secrets_manager' => 'secrets_manager',
        'default_combo' => PropertyDefinition::PLUGINS.default_value
      }.freeze

      # A publisher the StorageService can call into without doing any work of its own.
      class NoOpEventPublisher
        def publish(_event); end

        def subscribe(*); end
      end

      # A monitor service stub for the plugins that register a monitor type at construction
      # (custom_endpoint). No monitor is ever started here: the execute pipeline is driven without a
      # connect, so the endpoint plugin never asks for a running monitor.
      class StubMonitorService
        def register_type(*, **); end

        def run_if_absent(*, **)
          nil
        end
      end

      # A host list provider stub with a cluster id, for the blue/green plugin's provider setup on the
      # first execute. The stub db dialect does not advertise blue/green support, so the provider is
      # built without starting any monitoring threads.
      class StubHostListProvider
        def cluster_id
          'benchmark-cluster-id'
        end
      end

      # Builds a plugin manager for the given comma-separated plugin codes over the stub services,
      # with a real StorageService and the manager wired onto its own container.
      #
      # @param plugin_codes [String] the +wrapper_plugins+ value, e.g. 'failover'
      # @param storage_services [Array] every StorageService created is appended here so the caller
      #   can shut its cleanup thread down at the end of the run
      # @return [Services::PluginManager]
      def self.build_manager(plugin_codes, storage_services)
        container = BenchmarkServices.container(
          plugin_props(plugin_codes),
          current_connection: FakeMysql2Driver::FakeClient.new
        )

        storage_service = Utils::Storage::StorageService.new(event_publisher: NoOpEventPublisher.new, cleanup_interval: 9999)
        storage_services << storage_service
        container.storage_service = storage_service
        container.event_publisher = NoOpEventPublisher.new
        container.monitor_service = StubMonitorService.new
        container.host_service.define_singleton_method(:host_list_provider) { StubHostListProvider.new }
        # The blue/green plugin builds a status provider on its first execute, which reads prefixed
        # monitoring overrides off the connection service. There are none in the benchmark, so both
        # return an empty config.
        container.connection_service.define_singleton_method(:prefixed_wrapper_config) { {} }
        container.connection_service.define_singleton_method(:prefixed_driver_config) { {} }

        manager = Services::PluginManager.new(container)
        container.plugin_manager = manager
        manager
      end

      # Stops any blue/green status providers built during a run. The providers are held in a process
      # global, so a run that enabled the bg plugin must release them when it ends.
      def self.release_providers
        Plugins::BlueGreen::BlueGreenPlugin.clean_up_providers
      end

      # Runs the execute pipeline the way the query path does: a connection.query method against the
      # fake connection, carrying the SQL so the SQL-inspecting plugins run, with a constant-cost
      # target callable so the figure reflects the chain rather than any real work.
      #
      # @return [Object] the target callable's result (1)
      def self.run_execute(manager)
        manager.execute(RubyMethod::CONNECTION_QUERY, STUB_CONNECTION, -> { 1 }, sql: SQL)
      end

      # The connection properties for a chain. The secret id and region are always present so the
      # secrets_manager plugin can construct; the other plugins ignore them.
      def self.plugin_props(plugin_codes)
        {
          wrapper_plugins: plugin_codes,
          secret_id: 'benchmark-secret',
          secret_region: 'us-east-1'
        }
      end

      STUB_CONNECTION = BenchmarkServices::STUB_CONNECTION
    end
  end
end
