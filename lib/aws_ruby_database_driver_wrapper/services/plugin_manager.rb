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
require_relative '../ruby_method'
require_relative '../plugins/default_plugin'
require_relative '../plugins/failover_plugin'
require_relative '../plugins/iam_auth_plugin'
require_relative '../plugins/secrets_manager_plugin'

module AwsRubyDatabaseDriverWrapper
  module Services
    class PluginManager
      WEIGHT_RELATIVE_TO_PRIOR_PLUGIN = -1
      DEFAULT_PLUGINS = 'failover'
      NOOP_CALLABLE = -> {}.freeze
      private_constant :WEIGHT_RELATIVE_TO_PRIOR_PLUGIN, :DEFAULT_PLUGINS, :NOOP_CALLABLE

      @plugin_classes = {
        'failover' => Plugins::FailoverPlugin,
        'iam' => Plugins::IamAuthPlugin,
        'secretsManager' => Plugins::SecretsManagerPlugin
      }

      # The final list of plugins will be sorted by weight, starting from the lowest values up to
      # the highest values. The first plugin of the list will have the lowest weight, and the
      # last one will have the highest weight.
      @plugin_weights = {
        Plugins::FailoverPlugin => 400,
        Plugins::IamAuthPlugin => 1800,
        Plugins::SecretsManagerPlugin => 1900
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

      def connect(host_info, props, is_initial_connection, plugin_to_skip: nil)
        execute_with_subscribed_plugins(
          'connect',
          lambda do |plugin, next_plugin_callable|
            plugin.connect(host_info, props, is_initial_connection, next_plugin_callable)
          end,
          NOOP_CALLABLE,
          plugin_to_skip:
        )
      end

      def internal_connect(host_info, props, wrapper_override_props, is_initial_connection, plugin_to_skip: nil)
        execute_with_subscribed_plugins(
          'internal_connect',
          lambda do |plugin, next_plugin_callable|
            plugin.internal_connect(host_info, props, wrapper_override_props, is_initial_connection, next_plugin_callable)
          end,
          NOOP_CALLABLE,
          plugin_to_skip:
        )
      end

      def execute(ruby_method, current_conn, target_callable, *args, bounded_conn: nil, **kwargs, &block)
        if ruby_method.is_a?(MethodInfo)
          method_name = ruby_method.name

          if ruby_method.check_bounded_connection && !bounded_conn.nil? && !current_conn.nil? && (bounded_conn != current_conn)
            raise Errors::AwsError, "Method invoked against old connection: #{bounded_conn}"
          end
        else
          # Fallback for dynamic method names (method_missing with string)
          method_name = ruby_method.to_s
        end

        execute_with_subscribed_plugins(
          method_name,
          lambda do |plugin, next_plugin_callable|
            plugin.execute(method_name, next_plugin_callable, *args, **kwargs, &block)
          end,
          target_callable
        )
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
        plugin_codes = wrapper_props[:wrapper_plugins] || DEFAULT_PLUGINS
        codes_list = plugin_codes.split(',').map(&:strip)
        raise Errors::AwsError, 'Duplicate plugins detected' if codes_list.length != codes_list.uniq.length

        plugin_classes = plugin_codes.empty? ? [] : get_plugin_classes(codes_list, wrapper_props)

        plugins = plugin_classes.map do |plugin_class|
          plugin_class.new(service_container, wrapper_props)
        end

        plugins << Plugins::DefaultPlugin.new(service_container, wrapper_props)
        plugins
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
