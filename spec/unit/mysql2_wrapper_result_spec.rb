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
require 'aws_advanced_ruby_driver_wrapper/mysql'
require 'aws_advanced_ruby_driver_wrapper/services/plugin_manager'
require 'aws_advanced_ruby_driver_wrapper/services/service_container'
require 'aws_advanced_ruby_driver_wrapper/plugins/default_plugin'
require 'aws_advanced_ruby_driver_wrapper/errors'
require 'aws_advanced_ruby_driver_wrapper/utils/connection_config'

RSpec.describe AwsAdvancedRubyDriverWrapper::Mysql2WrapperResult do
  def build_service_container_with_plugins(plugins, current_connection = nil)
    plugin_manager = AwsAdvancedRubyDriverWrapper::Services::PluginManager.allocate
    plugin_manager.instance_variable_set(:@pipeline_cache, {})
    plugin_manager.instance_variable_set(:@plugins, plugins)
    connection_service = double('ConnectionService', current_connection: current_connection)
    container = AwsAdvancedRubyDriverWrapper::Services::ServiceContainer.new
    container.plugin_manager = plugin_manager
    container.connection_service = connection_service
    container
  end

  # A plugin that records calls and re-raises any error from the target function.
  class TrackingPlugin
    attr_reader :subscribed_methods, :calls, :caught_error

    def initialize
      @calls = []
      @caught_error = nil
      @subscribed_methods = Set['*']
    end

    def execute(target_method_name, pipeline_callable, ...)
      @calls << "before:#{target_method_name}"
      result = pipeline_callable.call(...)
      @calls << "after:#{target_method_name}"
      result
    rescue StandardError => e
      @caught_error = e
      @calls << "error:#{target_method_name}"
      raise
    end
  end

  describe '#each' do
    it 'routes a mid-iteration error through the plugin pipeline' do
      # Mock a streaming Mysql2::Result who's `each` call raises an exception on the 2nd row.
      mock_result = double('Mysql2::Result')
      allow(mock_result).to receive(:each).and_yield({ 'id' => 1 }).and_raise(
        Mysql2::Error, 'Lost connection to MySQL server during query'
      )

      mock_connection = double('Mysql2::Client')
      plugin = TrackingPlugin.new
      service_container = build_service_container_with_plugins([plugin], mock_connection)

      wrapper_result = described_class.new(mock_result, service_container, mock_connection)

      rows = []
      expect do
        wrapper_result.each { |row| rows << row }
      end.to raise_error(Mysql2::Error, /Lost connection/)

      # The first row was yielded before the error
      expect(rows).to eq([{ 'id' => 1 }])

      # The plugin saw the error go through the pipeline
      expect(plugin.calls).to eq(['before:result.each', 'error:result.each'])
      expect(plugin.caught_error).to be_a(Mysql2::Error)
    end

    it 'iterates successfully when no error occurs' do
      mock_result = double('Mysql2::Result')
      allow(mock_result).to receive(:each).and_yield({ 'id' => 1 }).and_yield({ 'id' => 2 })

      mock_connection = double('Mysql2::Client')
      plugin = TrackingPlugin.new
      service_container = build_service_container_with_plugins([plugin], mock_connection)

      wrapper_result = described_class.new(mock_result, service_container, mock_connection)

      rows = wrapper_result.map { |row| row }

      expect(rows).to eq([{ 'id' => 1 }, { 'id' => 2 }])
      expect(plugin.calls).to eq(['before:result.each', 'after:result.each'])
      expect(plugin.caught_error).to be_nil
    end

    it 'forwards args to the underlying result each method' do
      mock_result = double('Mysql2::Result')
      allow(mock_result).to receive(:each) do |*args, &blk|
        expect(args).to eq([{ as: :array }])
        blk.call([1, 'Alice'])
        blk.call([2, 'Bob'])
      end

      mock_connection = double('Mysql2::Client')
      plugin = TrackingPlugin.new
      service_container = build_service_container_with_plugins([plugin], mock_connection)

      wrapper_result = described_class.new(mock_result, service_container, mock_connection)

      rows = []
      wrapper_result.each(as: :array) { |row| rows << row }

      expect(rows).to eq([[1, 'Alice'], [2, 'Bob']])
    end
  end

  # Freeing a buffered result is local, but an unbuffered one still has whatever was not read on the
  # wire and libmysql drains it before letting the result go. mysql2 says so itself, at
  # ext/mysql2/result.c: "this may call flush_use_result, which can hit the socket". This used
  # to be delegated straight to the driver as a non-network call, which took that read past every
  # plugin and left an error raised while draining invisible to failover.
  describe '#free' do
    # A verifying double, so that a call on a method mysql2 does not define fails here rather than
    # against a real server.
    let(:result) { instance_double(Mysql2::Result) }
    let(:connection) { instance_double(Mysql2::Client) }
    let(:plugin) { TrackingPlugin.new }
    subject(:wrapper_result) do
      described_class.new(result, build_service_container_with_plugins([plugin], connection), connection)
    end

    it 'goes through the pipeline' do
      allow(result).to receive(:free)

      wrapper_result.free

      expect(result).to have_received(:free)
      expect(plugin.calls).to eq(['before:result.free', 'after:result.free'])
    end

    it 'routes an error raised while draining through the pipeline' do
      allow(result).to receive(:free).and_raise(Mysql2::Error, 'Lost connection to MySQL server during query')

      expect { wrapper_result.free }.to raise_error(Mysql2::Error, /Lost connection/)

      expect(plugin.calls).to eq(['before:result.free', 'error:result.free'])
      expect(plugin.caught_error).to be_a(Mysql2::Error)
    end

    # The rows still on the wire are only on the connection the statement was sent on.
    it 'is refused on any other connection' do
      allow(result).to receive(:free)
      other = described_class.new(result, build_service_container_with_plugins([plugin], connection),
                                  instance_double(Mysql2::Client))

      expect { other.free }.to raise_error(AwsAdvancedRubyDriverWrapper::Errors::AwsError, /old connection/)
      expect(result).not_to have_received(:free)
    end
  end
end
