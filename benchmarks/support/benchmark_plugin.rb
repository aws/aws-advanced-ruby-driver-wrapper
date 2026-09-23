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

module AwsAdvancedRubyDriverWrapper
  module Benchmarks
    # A no-op plugin that subscribes to every method and does nothing but hand control to the next
    # plugin in the pipeline. It exists to measure the pipeline's own per-call cost: with a chain of
    # these, the difference from an empty chain is the overhead the plugin manager adds.
    class BenchmarkPlugin
      SUBSCRIBED_METHODS = Set['*'].freeze

      def initialize(_service_container, _props); end

      def subscribed_methods
        SUBSCRIBED_METHODS
      end

      def connect(_host_info, _driver_props, _is_initial_connection, next_plugin_callable)
        next_plugin_callable.call
      end

      def internal_connect(_host_info, _driver_props, _wrapper_props, _is_initial_connection, next_plugin_callable)
        next_plugin_callable.call
      end

      def execute(_target_method_name, next_plugin_callable, *_args, **_kwargs, &)
        next_plugin_callable.call
      end

      # Registers +count+ distinct no-op plugin classes under the plugin manager, each with its own
      # code. Distinct classes and codes are required because the plugin manager loads plugins by
      # unique code and rejects duplicates, so a single class reused ten times cannot build a
      # ten-plugin chain through the real load path.
      #
      # @param count [Integer] how many no-op plugins to register
      # @return [Array<String>] the registered plugin codes, in registration order
      def self.register(count)
        Array.new(count) do |i|
          code = "benchmark_#{i}"
          Services::PluginManager.register_plugin(code, Class.new(BenchmarkPlugin))
          code
        end
      end
    end
  end
end
