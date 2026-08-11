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
require 'aws_ruby_database_driver_wrapper/mysql'
require 'aws_ruby_database_driver_wrapper/services/plugin_manager'
require 'aws_ruby_database_driver_wrapper/services/service_container'
require 'aws_ruby_database_driver_wrapper/plugins/default_plugin'
require 'aws_ruby_database_driver_wrapper/errors'
require 'aws_ruby_database_driver_wrapper/utils/connection_config'

RSpec.describe AwsRubyDatabaseDriverWrapper::Mysql2WrapperResult do
  def build_service_container_with_plugins(plugins, current_connection = nil)
    plugin_manager = AwsRubyDatabaseDriverWrapper::Services::PluginManager.allocate
    plugin_manager.instance_variable_set(:@pipeline_cache, {})
    plugin_manager.instance_variable_set(:@plugins, plugins)
    connection_service = double('ConnectionService', current_connection: current_connection)
    container = AwsRubyDatabaseDriverWrapper::Services::ServiceContainer.new
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

  # The rows are read after the call that produced them has returned, so a plugin which has to know
  # which columns a row holds can only learn it from the SQL the result carries.
  describe 'the SQL it publishes to the plugins' do
    let(:sql) { 'SELECT ssn FROM users' }
    let(:mysql_result) { double('Mysql2::Result') }
    let(:connection) { double('Mysql2::Client') }
    let(:recorded) { build_recording_container(connection) }
    let(:container) { recorded.first }
    let(:plugin) { recorded.last }
    subject(:wrapper_result) { described_class.new(mysql_result, container, connection, sql) }

    it 'publishes the SQL of the statement when the rows are iterated' do
      allow(mysql_result).to receive(:each)
      wrapper_result.each { |row| row }

      expect(plugin.sql_for('result.each')).to eq([sql])
    end

    it 'publishes the SQL of the statement when the rows are collected' do
      allow(mysql_result).to receive(:to_a).and_return([])
      wrapper_result.to_a

      expect(plugin.sql_for('result.to_a')).to eq([sql])
    end

    it 'publishes the SQL of the statement when a single row is read' do
      allow(mysql_result).to receive(:[]).and_return({})
      wrapper_result[0]

      expect(plugin.sql_for('result.[]')).to eq([sql])
    end

    it 'publishes the SQL of the statement for every read of the same result' do
      allow(mysql_result).to receive(:to_a).and_return([])
      wrapper_result.to_a
      wrapper_result.to_a

      expect(plugin.sql_for('result.to_a')).to eq([sql, sql])
    end

    # A result built by a call whose SQL the wrapper does not know, such as one that went through
    # method_missing, publishes nothing rather than the SQL of some other statement.
    it 'publishes no SQL when it was built without any' do
      allow(mysql_result).to receive(:to_a).and_return([])
      described_class.new(mysql_result, container, connection).to_a

      expect(plugin.sql_for('result.to_a')).to eq([nil])
    end
  end
end
