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

require 'logger'
require_relative '../errors'
require_relative '../property_definition'
require_relative '../ruby_method'
require_relative '../utils/sql_encoding'
require_relative '../plugins/default_plugin'
require_relative '../plugins/failover_plugin'
require_relative '../plugins/gdb/gdb_failover_plugin'
require_relative '../plugins/iam_auth_plugin'
require_relative '../plugins/initial_connection_strategy_plugin'
require_relative '../plugins/kms_encryption/kms_encryption_plugin'
require_relative '../plugins/secrets_manager_plugin'
require_relative '../plugins/blue_green/blue_green_plugin'
require_relative '../plugins/custom_endpoint/custom_endpoint_plugin'
require_relative 'plugin_call_context'

module AwsAdvancedRubyDriverWrapper
  module Services
    class PluginManager
      WEIGHT_RELATIVE_TO_PRIOR_PLUGIN = -1
      NOOP_CALLABLE = -> {}.freeze
      CURRENT_CALL_CONTEXT_KEY = :aws_ruby_wrapper_plugin_call_context
      private_constant :WEIGHT_RELATIVE_TO_PRIOR_PLUGIN, :NOOP_CALLABLE, :CURRENT_CALL_CONTEXT_KEY

      @plugin_classes = {
        'bg' => Plugins::BlueGreen::BlueGreenPlugin,
        'custom_endpoint' => Plugins::CustomEndpoint::CustomEndpointPlugin,
        'failover' => Plugins::FailoverPlugin,
        'gdb_failover' => Plugins::Gdb::GdbFailoverPlugin,
        'iam' => Plugins::IamAuthPlugin,
        'initial_connection' => Plugins::InitialConnectionStrategyPlugin,
        'kms_encryption' => Plugins::KmsEncryptionPlugin,
        'secrets_manager' => Plugins::SecretsManagerPlugin
      }

      # The final list of plugins will be sorted by weight, starting from the lowest values up to
      # the highest values. The first plugin of the list will have the lowest weight, and the
      # last one will have the highest weight.
      @plugin_weights = {
        Plugins::BlueGreen::BlueGreenPlugin => 200,
        Plugins::CustomEndpoint::CustomEndpointPlugin => 250,
        Plugins::InitialConnectionStrategyPlugin => 300,
        Plugins::FailoverPlugin => 400,
        Plugins::Gdb::GdbFailoverPlugin => 500,
        Plugins::IamAuthPlugin => 1800,
        Plugins::SecretsManagerPlugin => 1900,
        Plugins::KmsEncryptionPlugin => 2050
      }

      class << self
        def register_plugin(plugin_code, plugin_class, weight: WEIGHT_RELATIVE_TO_PRIOR_PLUGIN)
          @plugin_classes[plugin_code] = plugin_class
          @plugin_weights[plugin_class] = weight
        end

        attr_reader :plugin_classes, :plugin_weights
      end

      def initialize(service_container)
        @plugins = load_plugins(service_container)
        @pipeline_cache = {}
      end

      def connect(host_info, driver_props, is_initial_connection, plugin_to_skip: nil)
        execute_with_subscribed_plugins(
          'connect',
          lambda do |plugin, next_plugin_callable|
            plugin.connect(host_info, driver_props, is_initial_connection, next_plugin_callable)
          end,
          NOOP_CALLABLE,
          plugin_to_skip:
        )
      end

      def internal_connect(host_info, driver_props, wrapper_props, is_initial_connection, plugin_to_skip: nil)
        execute_with_subscribed_plugins(
          'internal_connect',
          lambda do |plugin, next_plugin_callable|
            plugin.internal_connect(host_info, driver_props, wrapper_props, is_initial_connection, next_plugin_callable)
          end,
          NOOP_CALLABLE,
          plugin_to_skip:
        )
      end

      # The context of the call currently being executed, for plugins that need to know more about
      # it than their own arguments say, or that need to change the arguments the target driver
      # method is called with. See {PluginCallContext}.
      #
      # The context belongs to the calling thread and is restored when the call returns, so nested
      # calls cannot see one another's.
      #
      # @return [PluginCallContext, nil] nil outside of a call
      def current_call_context
        Thread.current[CURRENT_CALL_CONTEXT_KEY]
      end

      # @return [String, nil] the SQL the call currently being executed originated from
      def current_sql
        current_call_context&.sql
      end

      # @param sql [String, nil] the SQL the call originated from, for plugins that inspect
      #   statements; it is published as valid UTF-8 (see {Utils::SqlEncoding.inspectable}), and is
      #   consumed here and never forwarded to the target driver method. Since invalid bytes in the
      #   published copy are replaced, a plugin that rewrites the SQL builds the new statement from
      #   the call's arguments rather than from this copy
      # @param field_names [Array<String>, Proc, nil] the result's column names in order, for a
      #   plugin that reads rows as arrays; like +sql+, it is consumed here rather than forwarded
      def execute(ruby_method, current_conn, target_callable, *args, bounded_conn: nil, sql: nil, field_names: nil, **kwargs, &block)
        if ruby_method.is_a?(MethodInfo)
          method_name = ruby_method.name

          if ruby_method.check_bounded_connection && !bounded_conn.nil? && !current_conn.nil? && (bounded_conn != current_conn)
            raise Errors::AwsError, "Method invoked against old connection: #{bounded_conn}"
          end
        else
          # Fallback for dynamic method names (method_missing with string)
          method_name = ruby_method.to_s
        end

        context = PluginCallContext.new(Utils::SqlEncoding.inspectable(sql), args, block, field_names)
        previous_context = Thread.current[CURRENT_CALL_CONTEXT_KEY]
        Thread.current[CURRENT_CALL_CONTEXT_KEY] = context

        begin
          execute_with_subscribed_plugins(
            method_name,
            lambda do |plugin, next_plugin_callable|
              # Read from the context rather than from args and block, so that a plugin which
              # replaced either is honoured by the plugins after it and by the target method.
              plugin.execute(method_name, next_plugin_callable, *context.args, **kwargs, &context.block)
            end,
            target_callable
          )
        ensure
          Thread.current[CURRENT_CALL_CONTEXT_KEY] = previous_context
        end
      end

      def num_plugins
        @plugins&.length || 0
      end

      def plugin_in_use?(plugin_class)
        return false if @plugins.nil? || @plugins.empty?

        @plugins.any?(plugin_class)
      end

      private

      def load_plugins(service_container)
        wrapper_props = service_container.connection_service.wrapper_props
        plugin_codes = PropertyDefinition::PLUGINS.get(wrapper_props)
        codes_list = plugin_codes.split(',').map(&:strip)
        ensure_single_auth_plugin(codes_list)
        ensure_single_failover_plugin(codes_list)
        raise Errors::AwsError, 'Duplicate plugins detected' if codes_list.length != codes_list.uniq.length

        plugin_classes = plugin_codes.empty? ? [] : get_plugin_classes(codes_list, wrapper_props)

        plugins = plugin_classes.map do |plugin_class|
          plugin_class.new(service_container, wrapper_props)
        end

        plugins << Plugins::DefaultPlugin.new(service_container, wrapper_props)
        plugins
      end

      def ensure_single_auth_plugin(plugin_code_list)
        auth_plugins_used = plugin_code_list & %w[iam secrets_manager].freeze

        return unless auth_plugins_used.length > 1

        raise Errors::PluginConflictError,
              "Only one authentication plugin may be used at a time. Found: #{auth_plugins_used.join(', ')}"
      end

      def ensure_single_failover_plugin(plugin_code_list)
        failover_plugins_used = plugin_code_list & %w[failover gdb_failover].freeze

        return unless failover_plugins_used.length > 1

        raise Errors::PluginConflictError,
              "Only one failover plugin may be used at a time. Found: #{failover_plugins_used.join(', ')}"
      end

      def get_plugin_classes(plugin_code_list, _wrapper_props)
        plugin_classes = plugin_code_list.map do |plugin_code|
          plugin_class = self.class.plugin_classes[plugin_code]
          raise Errors::AwsError, "Invalid plugin: #{plugin_code}" if plugin_class.nil?

          plugin_class
        end

        return [] if plugin_classes.empty?

        weights = plugin_weights_for(plugin_classes)
        plugin_classes.sort_by! { |ft| weights[ft] }

        plugin_classes
      end

      def plugin_weights_for(plugin_classes)
        last_weight = 0
        plugin_classes.each_with_object({}) do |plugin_class, weights|
          weight = self.class.plugin_weights[plugin_class]

          if weight.nil? || weight == WEIGHT_RELATIVE_TO_PRIOR_PLUGIN
            last_weight += 1
            weights[plugin_class] = last_weight
          else
            weights[plugin_class] = weight
            last_weight = weight
          end
        end
      end

      def execute_with_subscribed_plugins(
        target_method_name,
        plugin_callable,
        target_driver_callable,
        plugin_to_skip: nil
      )
        pipeline_callable = @pipeline_cache[target_method_name] ||= make_pipeline(target_method_name)
        pipeline_callable.call(plugin_callable, target_driver_callable, target_method_name, plugin_to_skip)
      end

      # Builds the plugin pipeline function chain. The pipeline allows plugins to perform logic both before and after
      # the target driver function is called.
      def make_pipeline(target_method_name)
        subscribed_plugins = @plugins.select do |p|
          p.subscribed_methods.include?('*') || p.subscribed_methods.include?(target_method_name)
        end
        raise Errors::AwsError, 'Plugin pipeline is nil' if subscribed_plugins.empty?

        base_plugin = subscribed_plugins.last
        base = lambda do |plugin_callable, target_driver_callable, *, **|
          plugin_callable.call(base_plugin, target_driver_callable)
        end

        subscribed_plugins[0...-1].reverse.reduce(base) do |next_plugin_callable, plugin|
          lambda do |plugin_callable, target_driver_callable, method_name, plugin_to_skip|
            if plugin_to_skip == plugin
              next_plugin_callable.call(plugin_callable, target_driver_callable, method_name, plugin_to_skip)
            else
              plugin_callable.call(plugin, lambda do
                next_plugin_callable.call(plugin_callable, target_driver_callable, method_name, plugin_to_skip)
              end)
            end
          end
        end
      end
    end
  end
end
