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

require_relative '../../spec_helper'
require 'aws_ruby_database_driver_wrapper/services/plugin_manager_service'
require 'aws_ruby_database_driver_wrapper/services/service_container'
require 'aws_ruby_database_driver_wrapper/plugins/default_plugin'
require 'aws_ruby_database_driver_wrapper/plugins/failover_plugin'
require 'aws_ruby_database_driver_wrapper/host/host_info'
require 'aws_ruby_database_driver_wrapper/errors'
require 'aws_ruby_database_driver_wrapper/utils/connection_config'

# Test plugin helpers that track calls in an array to verify plugin pipeline ordering.
module TestPlugins
  # Base test plugin. Subscribes to all methods ('*'). Records events before/after target function call.
  class TestPlugin
    attr_reader :subscribed_methods

    def initialize(calls, connection = nil)
      @calls = calls
      @connection = connection
      @subscribed_methods = Set['*']
    end

    def connect(_host_info, _props, _is_initial_connection, pipeline_callable)
      @calls << "#{self.class.name.split('::').last}:before connect"
      result = @connection || pipeline_callable.call
      @calls << "#{self.class.name.split('::').last}:after connect"
      result
    end

    def execute(_target_obj, _target_method_name, pipeline_callable, *_args, **_options)
      @calls << "#{self.class.name.split('::').last}:before execute"
      result = pipeline_callable.call
      @calls << "#{self.class.name.split('::').last}:after execute"
      result
    end
  end

  # Subscribes to all methods. Identical to TestPlugin.
  class TestPluginOne < TestPlugin; end

  # Subscribes only to 'test_call_a' and 'test_call_b'.
  class TestPluginTwo < TestPlugin
    def initialize(calls, connection = nil)
      super
      @subscribed_methods = Set['test_call_a', 'test_call_b']
    end
  end

  # Subscribes to 'test_call_a' and 'connect'.
  class TestPluginThree < TestPlugin
    def initialize(calls, connection = nil)
      super
      @subscribed_methods = Set['test_call_a', 'connect']
    end
  end

  # Subscribes to all methods. Raises an error either before or after calling next.
  class TestPluginRaisesError < TestPlugin
    def initialize(calls, throw_before_call = true)
      super(calls)
      @throw_before_call = throw_before_call
    end

    def connect(_host_info, _props, _is_initial_connection, pipeline_callable)
      @calls << "#{self.class.name.split('::').last}:before connect"
      raise AwsRubyDatabaseDriverWrapper::Errors::AwsError, 'test error' if @throw_before_call

      pipeline_callable.call
      @calls << "#{self.class.name.split('::').last}:after connect"
      raise AwsRubyDatabaseDriverWrapper::Errors::AwsError, 'test error'
    end

    def execute(_target_obj, _target_method_name, pipeline_callable, *_args, **_options)
      @calls << "#{self.class.name.split('::').last}:before execute"
      raise AwsRubyDatabaseDriverWrapper::Errors::AwsError, 'test error' if @throw_before_call

      pipeline_callable.call
      @calls << "#{self.class.name.split('::').last}:after execute"
      raise AwsRubyDatabaseDriverWrapper::Errors::AwsError, 'test error'
    end
  end
end

RSpec.describe AwsRubyDatabaseDriverWrapper::Services::PluginManagerService do
  # Helper to build a PluginService with directly injected plugins (bypassing factory loading).
  def build_manager_with_plugins(plugins)
    manager = AwsRubyDatabaseDriverWrapper::Services::PluginManagerService.allocate
    manager.instance_variable_set(:@plugins, plugins)
    manager.instance_variable_set(:@pipeline_cache, {})
    manager
  end

  describe '#execute' do
    context 'when all three plugins subscribe to the method (test_call_a)' do
      it 'calls all plugins in correct before/after order' do
        calls = []
        plugins = [
          TestPlugins::TestPluginOne.new(calls),
          TestPlugins::TestPluginTwo.new(calls),
          TestPlugins::TestPluginThree.new(calls)
        ]
        manager = build_manager_with_plugins(plugins)

        target_obj = Object.new
        result = manager.execute(nil, nil, target_obj, 'test_call_a', lambda {
          calls << 'target_call'
          'result_value'
        })

        expect(result).to eq('result_value')
        expect(calls).to eq([
                              'TestPluginOne:before execute',
                              'TestPluginTwo:before execute',
                              'TestPluginThree:before execute',
                              'target_call',
                              'TestPluginThree:after execute',
                              'TestPluginTwo:after execute',
                              'TestPluginOne:after execute'
                            ])
      end
    end

    context 'when only two plugins subscribe to the method (test_call_b)' do
      it 'skips unsubscribed plugins' do
        calls = []
        plugins = [
          TestPlugins::TestPluginOne.new(calls),
          TestPlugins::TestPluginTwo.new(calls),
          TestPlugins::TestPluginThree.new(calls)
        ]
        manager = build_manager_with_plugins(plugins)

        result = manager.execute(nil, nil, Object.new, 'test_call_b', lambda {
          calls << 'target_call'
          'result_value'
        })

        expect(result).to eq('result_value')
        expect(calls).to eq([
                              'TestPluginOne:before execute',
                              'TestPluginTwo:before execute',
                              'target_call',
                              'TestPluginTwo:after execute',
                              'TestPluginOne:after execute'
                            ])
      end
    end

    context 'when only one plugin subscribes to the method (test_call_c)' do
      it 'only calls the subscribed plugin' do
        calls = []
        plugins = [
          TestPlugins::TestPluginOne.new(calls),
          TestPlugins::TestPluginTwo.new(calls),
          TestPlugins::TestPluginThree.new(calls)
        ]
        manager = build_manager_with_plugins(plugins)

        result = manager.execute(nil, nil, Object.new, 'test_call_c', lambda {
          calls << 'target_call'
          'result_value'
        })

        expect(result).to eq('result_value')
        expect(calls).to eq([
                              'TestPluginOne:before execute',
                              'target_call',
                              'TestPluginOne:after execute'
                            ])
      end
    end
  end

  describe '#connect' do
    it 'calls subscribed plugins in correct order and returns the connection' do
      calls = []
      mock_conn = double('Connection')
      plugins = [
        TestPlugins::TestPluginOne.new(calls),
        TestPlugins::TestPluginTwo.new(calls),
        TestPlugins::TestPluginThree.new(calls, mock_conn)
      ]
      manager = build_manager_with_plugins(plugins)

      host_info = AwsRubyDatabaseDriverWrapper::Host::HostInfo.new(host: 'localhost')
      result = manager.connect(host_info, nil, true)

      expect(result).to eq(mock_conn)
      expect(calls).to eq([
                            'TestPluginOne:before connect',
                            'TestPluginThree:before connect',
                            'TestPluginThree:after connect',
                            'TestPluginOne:after connect'
                          ])
    end

    it 'skips the specified plugin when plugin_to_skip is provided' do
      calls = []
      mock_conn = double('Connection')
      plugin_one = TestPlugins::TestPluginOne.new(calls)
      plugins = [
        plugin_one,
        TestPlugins::TestPluginTwo.new(calls),
        TestPlugins::TestPluginThree.new(calls, mock_conn)
      ]
      manager = build_manager_with_plugins(plugins)

      host_info = AwsRubyDatabaseDriverWrapper::Host::HostInfo.new(host: 'localhost')
      result = manager.connect(host_info, nil, true, plugin_to_skip: plugin_one)

      expect(result).to eq(mock_conn)
      expect(calls).to eq([
                            'TestPluginThree:before connect',
                            'TestPluginThree:after connect'
                          ])
    end
  end

  describe '#connect with exceptions' do
    context 'when a plugin raises an error before calling next' do
      it 'propagates the error and stops the pipeline' do
        calls = []
        plugins = [
          TestPlugins::TestPluginOne.new(calls),
          TestPlugins::TestPluginTwo.new(calls),
          TestPlugins::TestPluginRaisesError.new(calls, true),
          TestPlugins::TestPluginThree.new(calls)
        ]
        manager = build_manager_with_plugins(plugins)

        host_info = AwsRubyDatabaseDriverWrapper::Host::HostInfo.new(host: 'localhost')
        expect { manager.connect(host_info, nil, true) }.to raise_error(AwsRubyDatabaseDriverWrapper::Errors::AwsError)

        expect(calls).to eq([
                              'TestPluginOne:before connect',
                              'TestPluginRaisesError:before connect'
                            ])
      end
    end

    context 'when a plugin raises an error after calling next' do
      it 'propagates the error after downstream plugins complete' do
        calls = []
        plugins = [
          TestPlugins::TestPluginOne.new(calls),
          TestPlugins::TestPluginTwo.new(calls),
          TestPlugins::TestPluginRaisesError.new(calls, false),
          TestPlugins::TestPluginThree.new(calls)
        ]
        manager = build_manager_with_plugins(plugins)

        host_info = AwsRubyDatabaseDriverWrapper::Host::HostInfo.new(host: 'localhost')
        expect { manager.connect(host_info, nil, true) }.to raise_error(AwsRubyDatabaseDriverWrapper::Errors::AwsError)

        expect(calls).to eq([
                              'TestPluginOne:before connect',
                              'TestPluginRaisesError:before connect',
                              'TestPluginThree:before connect',
                              'TestPluginThree:after connect',
                              'TestPluginRaisesError:after connect'
                            ])
      end
    end
  end

  describe 'pipeline caching' do
    it 'builds the pipeline only once per method name' do
      calls = []
      plugins = [
        TestPlugins::TestPluginOne.new(calls),
        TestPlugins::TestPluginTwo.new(calls)
      ]
      manager = build_manager_with_plugins(plugins)

      target = Object.new
      3.times do
        manager.execute(nil, nil, target, 'test_call_a', -> { 'result' })
      end

      cache = manager.instance_variable_get(:@pipeline_cache)
      expect(cache).to have_key('test_call_a')
      expect(cache.size).to eq(1)

      # Call a different method to verify it gets its own cache entry
      manager.execute(nil, nil, target, 'test_call_b', -> { 'result' })
      expect(cache).to have_key('test_call_b')
      expect(cache.size).to eq(2)
    end

    it 'reuses the same pipeline object across calls' do
      calls = []
      plugins = [TestPlugins::TestPluginOne.new(calls)]
      manager = build_manager_with_plugins(plugins)

      manager.execute(nil, nil, Object.new, 'test_call_a', -> { 'result' })
      first_pipeline = manager.instance_variable_get(:@pipeline_cache)['test_call_a']

      manager.execute(nil, nil, Object.new, 'test_call_a', -> { 'result' })
      second_pipeline = manager.instance_variable_get(:@pipeline_cache)['test_call_a']

      expect(first_pipeline).to equal(second_pipeline)
    end
  end

  def service_container_with_wrapper_props(wrapper_props = {})
    container = AwsRubyDatabaseDriverWrapper::Services::ServiceContainer.new
    connection_service = double('ConnectionService', wrapper_props: wrapper_props)
    container.connection_service = connection_service
    container
  end

  describe 'plugin loading' do
    it 'loads only the default plugin when plugins option is empty' do
      container = service_container_with_wrapper_props(wrapper_plugins: '')
      manager = described_class.new(container)

      expect(manager.num_plugins).to eq(1)
      expect(manager.plugin_in_use?(AwsRubyDatabaseDriverWrapper::Plugins::DefaultPlugin)).to be true
    end

    it 'loads default plugins (failover + default) when no plugins option specified' do
      container = service_container_with_wrapper_props
      manager = described_class.new(container)

      expect(manager.num_plugins).to eq(2)
      expect(manager.plugin_in_use?(AwsRubyDatabaseDriverWrapper::Plugins::FailoverPlugin)).to be true
      expect(manager.plugin_in_use?(AwsRubyDatabaseDriverWrapper::Plugins::DefaultPlugin)).to be true
    end

    it 'raises an error when an invalid plugin code is passed' do
      container = service_container_with_wrapper_props(wrapper_plugins: 'nonexistent_plugin')
      expect { described_class.new(container) }
        .to raise_error(AwsRubyDatabaseDriverWrapper::Errors::AwsError, 'Invalid plugin: nonexistent_plugin')
    end

    it 'does not sort the plugin list when auto_sort_plugins is false' do
      stub_plugin_a = Class.new(AwsRubyDatabaseDriverWrapper::Plugins::DefaultPlugin)
      stub_plugin_b = Class.new(AwsRubyDatabaseDriverWrapper::Plugins::DefaultPlugin)

      described_class.register_plugin('plugin_a', stub_plugin_a, weight: 900)
      described_class.register_plugin('plugin_b', stub_plugin_b, weight: 100)

      container = service_container_with_wrapper_props(wrapper_plugins: 'plugin_a,plugin_b', auto_sort_plugins: false)
      manager = described_class.new(container)
      plugins = manager.instance_variable_get(:@plugins)

      # DefaultPlugin is always appended last; the first two should preserve insertion order
      expect(plugins[0]).to be_a(stub_plugin_a)
      expect(plugins[1]).to be_a(stub_plugin_b)
    ensure
      described_class.plugin_classes.delete('plugin_a')
      described_class.plugin_classes.delete('plugin_b')
      described_class.plugin_weights.delete(stub_plugin_a)
      described_class.plugin_weights.delete(stub_plugin_b)
    end
  end
end
