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

require_relative '../spec_helper'
require 'aws_ruby_database_driver_wrapper/services/plugin_manager'
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

    def execute(_target_method_name, pipeline_callable, *_args, **_options)
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

  # Subscribes to all methods. Stands in for the last plugin of the pipeline, which is the only one
  # whose pipeline callable is the target driver method: it hands the arguments and the block it was
  # given straight to it, the way the default plugin does.
  class TestPluginCallsTarget < TestPlugin
    def execute(_target_method_name, target_callable, ...)
      target_callable.call(...)
    end
  end

  # Subscribes to all methods. Reads the call context the manager published, and can replace the
  # arguments or the block that the plugins after it, and the target method, are called with.
  class TestPluginReadsContext < TestPlugin
    attr_accessor :manager
    attr_reader :seen_sql, :seen_args

    def initialize(calls, new_args: nil, new_block: nil)
      super(calls)
      @new_args = new_args
      @new_block = new_block
    end

    def execute(_target_method_name, pipeline_callable, *args, **_options)
      context = @manager.current_call_context
      @seen_sql = context&.sql
      @seen_args = args
      context.args = @new_args unless @new_args.nil?
      context.block = @new_block unless @new_block.nil?

      pipeline_callable.call
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

    def execute(_target_method_name, pipeline_callable, *_args, **_options)
      @calls << "#{self.class.name.split('::').last}:before execute"
      raise AwsRubyDatabaseDriverWrapper::Errors::AwsError, 'test error' if @throw_before_call

      pipeline_callable.call
      @calls << "#{self.class.name.split('::').last}:after execute"
      raise AwsRubyDatabaseDriverWrapper::Errors::AwsError, 'test error'
    end
  end
end

RSpec.describe AwsRubyDatabaseDriverWrapper::Services::PluginManager do
  # Helper to build a PluginManager with directly injected plugins (bypassing factory loading).
  def build_manager_with_plugins(plugins)
    manager = AwsRubyDatabaseDriverWrapper::Services::PluginManager.allocate
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

        result = manager.execute('test_call_a', nil, lambda {
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

        result = manager.execute('test_call_b', nil, lambda {
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

        result = manager.execute('test_call_c', nil, lambda {
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

  describe '#current_call_context' do
    # Builds a manager whose pipeline ends in a plugin that calls the target with what it was given,
    # so that what a plugin changed about the call can be seen at the target.
    def build_manager_with_context_plugin(context_plugin)
      manager = build_manager_with_plugins([context_plugin, TestPlugins::TestPluginCallsTarget.new([])])
      context_plugin.manager = manager
      manager
    end

    it 'is nil outside of a call' do
      manager = build_manager_with_plugins([TestPlugins::TestPluginOne.new([])])

      expect(manager.current_call_context).to be_nil
      expect(manager.current_sql).to be_nil
    end

    # A result method has no SQL among its arguments, and a prepared statement only carries the name
    # it was prepared under, so the caller states the SQL separately.
    it 'publishes the SQL the call originated from' do
      context_plugin = TestPlugins::TestPluginReadsContext.new([])
      manager = build_manager_with_context_plugin(context_plugin)

      manager.execute('test_call_a', nil, ->(*) {}, 0, sql: 'SELECT ssn FROM users')

      expect(context_plugin.seen_sql).to eq('SELECT ssn FROM users')
    end

    it 'has no SQL when the caller did not say what it was' do
      context_plugin = TestPlugins::TestPluginReadsContext.new([])
      manager = build_manager_with_context_plugin(context_plugin)

      manager.execute('test_call_a', nil, -> {})

      expect(context_plugin.seen_sql).to be_nil
    end

    it 'does not pass the SQL to the target method as an argument' do
      received = nil
      manager = build_manager_with_plugins([TestPlugins::TestPluginCallsTarget.new([])])

      manager.execute('test_call_a', nil, lambda { |*args, **kwargs|
        received = [args, kwargs]
      }, 'SELECT $1', ['Jo'], sql: 'SELECT $1')

      expect(received).to eq([['SELECT $1', ['Jo']], {}])
    end

    # This is how the kms_encryption plugin substitutes an encrypted bind parameter without touching the
    # array the application passed.
    it 'lets a plugin replace the arguments the target method is called with' do
      context_plugin = TestPlugins::TestPluginReadsContext.new([], new_args: ['SELECT $1', ['encrypted']])
      manager = build_manager_with_context_plugin(context_plugin)
      received = nil

      manager.execute('test_call_a', nil, ->(*args) { received = args }, 'SELECT $1', ['Jo'])

      expect(context_plugin.seen_args).to eq(['SELECT $1', ['Jo']])
      expect(received).to eq(['SELECT $1', ['encrypted']])
    end

    it 'passes the replaced arguments to the plugins after the one that replaced them' do
      first = TestPlugins::TestPluginReadsContext.new([], new_args: %w[replaced])
      second = TestPlugins::TestPluginReadsContext.new([])
      manager = build_manager_with_plugins([first, second, TestPlugins::TestPluginCallsTarget.new([])])
      first.manager = manager
      second.manager = manager

      manager.execute('test_call_a', nil, ->(*) {}, 'original')

      expect(second.seen_args).to eq(%w[replaced])
    end

    # A result method yields its rows rather than returning them, so decrypting them means
    # replacing the block the driver is called with.
    it 'lets a plugin replace the block the target method is called with' do
      yielded = []
      context_plugin = TestPlugins::TestPluginReadsContext.new([], new_block: ->(row) { yielded << "wrapped:#{row}" })
      manager = build_manager_with_context_plugin(context_plugin)

      manager.execute('test_call_a', nil, ->(&block) { block.call('row') }) { |row| yielded << row }

      expect(yielded).to eq(['wrapped:row'])
    end

    # Reading a result runs inside the call that produced it, and neither call may see the other's
    # SQL.
    it 'restores the context of the outer call when a nested call returns' do
      manager = build_manager_with_plugins([TestPlugins::TestPluginOne.new([])])
      inner_sql = nil
      outer_sql = nil

      manager.execute('test_call_a', nil, lambda {
        manager.execute('test_call_a', nil, -> { inner_sql = manager.current_sql }, sql: 'SELECT 2')
        outer_sql = manager.current_sql
      }, sql: 'SELECT 1')

      expect(inner_sql).to eq('SELECT 2')
      expect(outer_sql).to eq('SELECT 1')
      expect(manager.current_call_context).to be_nil
    end

    it 'clears the context when the call raises' do
      manager = build_manager_with_plugins([TestPlugins::TestPluginOne.new([])])

      expect do
        manager.execute('test_call_a', nil, -> { raise AwsRubyDatabaseDriverWrapper::Errors::AwsError, 'test error' },
                        sql: 'SELECT 1')
      end.to raise_error(AwsRubyDatabaseDriverWrapper::Errors::AwsError)

      expect(manager.current_call_context).to be_nil
    end

    # The context belongs to the thread that is making the call, so a connection used from another
    # thread cannot read its SQL.
    it 'is not visible to another thread' do
      manager = build_manager_with_plugins([TestPlugins::TestPluginOne.new([])])
      other_thread_sql = :not_set

      manager.execute('test_call_a', nil, lambda {
        other_thread_sql = Thread.new { manager.current_sql }.value
      }, sql: 'SELECT 1')

      expect(other_thread_sql).to be_nil
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

      3.times do
        manager.execute('test_call_a', nil, -> { 'result' })
      end

      cache = manager.instance_variable_get(:@pipeline_cache)
      expect(cache).to have_key('test_call_a')
      expect(cache.size).to eq(1)

      # Call a different method to verify it gets its own cache entry
      manager.execute('test_call_b', nil, -> { 'result' })
      expect(cache).to have_key('test_call_b')
      expect(cache.size).to eq(2)
    end

    it 'reuses the same pipeline object across calls' do
      calls = []
      plugins = [TestPlugins::TestPluginOne.new(calls)]
      manager = build_manager_with_plugins(plugins)

      manager.execute('test_call_a', nil, -> { 'result' })
      first_pipeline = manager.instance_variable_get(:@pipeline_cache)['test_call_a']

      manager.execute('test_call_a', nil, -> { 'result' })
      second_pipeline = manager.instance_variable_get(:@pipeline_cache)['test_call_a']

      expect(first_pipeline).to equal(second_pipeline)
    end
  end

  def service_container_with_wrapper_props(wrapper_props = {})
    container = AwsRubyDatabaseDriverWrapper::Services::ServiceContainer.new
    connection_service = double('ConnectionService', wrapper_props: wrapper_props, driver_props: Concurrent::Map.new)
    driver_dialect = double('DriverDialect', network_bound_methods: Set['connect'])
    dialect_service = double('DialectService', driver_dialect: driver_dialect)
    container.connection_service = connection_service
    container.dialect_service = dialect_service
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

    it 'raises an error when duplicate plugin codes are passed' do
      container = service_container_with_wrapper_props(wrapper_plugins: 'failover,failover')
      expect { described_class.new(container) }
        .to raise_error(AwsRubyDatabaseDriverWrapper::Errors::AwsError, 'Duplicate plugins detected')
    end

    it 'loads the KMS kms_encryption plugin for the kms_encryption code' do
      container = service_container_with_wrapper_props(wrapper_plugins: 'kms_encryption')
      manager = described_class.new(container)

      expect(manager.plugin_in_use?(AwsRubyDatabaseDriverWrapper::Plugins::KmsEncryptionPlugin)).to be true
    end

    # The kms_encryption plugin has to see the parameters and the rows last on the way out and first on
    # the way back, so that everything before it works with plaintext.
    it 'orders the KMS kms_encryption plugin after the failover plugin' do
      container = service_container_with_wrapper_props(wrapper_plugins: 'kms_encryption,failover')
      manager = described_class.new(container)

      plugin_classes = manager.instance_variable_get(:@plugins).map(&:class)
      expect(plugin_classes.index(AwsRubyDatabaseDriverWrapper::Plugins::KmsEncryptionPlugin))
        .to be > plugin_classes.index(AwsRubyDatabaseDriverWrapper::Plugins::FailoverPlugin)
    end

    it 'does not raise an error when all plugin codes are unique' do
      container = service_container_with_wrapper_props(wrapper_plugins: 'failover')
      expect { described_class.new(container) }.not_to raise_error
    end
  end
end
