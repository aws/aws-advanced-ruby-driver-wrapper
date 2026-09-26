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

    # In ActiveRecord's array mode the rows come back without column names, so the reads publish the
    # result's field list for a plugin to match each position against.
    it 'publishes the result column names when the rows can come back as arrays' do
      allow(mysql_result).to receive_messages(fields: %w[ssn], each: nil, to_a: [], :[] => {})

      wrapper_result.each { |row| row }
      wrapper_result.to_a
      wrapper_result[0]

      %w[result.each result.to_a result.[]].each do |method|
        expect(plugin.field_names_for(method)).to eq([%w[ssn]]), method
      end
    end

    # A prepared-statement result that fetched no rows reads its column names from the statement's
    # metadata rather than from Mysql2::Result#fields: mysql2 leaves the result's field pointer
    # unpopulated for an empty prepared-statement result, so reading it there loses the column names
    # or, on some client libraries, segfaults.
    it 'reads column names from the statement when an empty result came from one' do
      statement = double('Mysql2::Statement', fields: %w[ssn])
      allow(mysql_result).to receive_messages(count: 0, to_a: [])

      # mysql_result is a plain double with no :fields stub, so if the result's fields were read
      # instead of the statement's, this would raise rather than return the statement's columns.
      described_class.new(mysql_result, container, connection, sql, statement).to_a

      expect(plugin.field_names_for('result.to_a')).to eq([%w[ssn]])
    end

    # Once a prepared-statement result has fetched rows its field cache is populated, so its own
    # fields are safe to read and are the only source that reflects options like symbolize_keys.
    it 'reads column names from the result when a prepared-statement result has rows' do
      statement = double('Mysql2::Statement', fields: %w[ssn])
      allow(mysql_result).to receive_messages(count: 1, fields: %i[ssn], to_a: [{ ssn: '1' }])

      described_class.new(mysql_result, container, connection, sql, statement).to_a

      expect(plugin.field_names_for('result.to_a')).to eq([%i[ssn]])
    end

    # A result built by a call whose SQL the wrapper does not know, such as one that went through
    # method_missing, publishes nothing rather than the SQL of some other statement.
    it 'publishes no SQL when it was built without any' do
      allow(mysql_result).to receive(:to_a).and_return([])
      described_class.new(mysql_result, container, connection).to_a

      expect(plugin.sql_for('result.to_a')).to eq([nil])
    end

    # Draining an unbuffered result reads whatever rows are still on the wire, which belong to the
    # statement the result came from.
    it 'publishes the SQL of the statement when the result is freed' do
      allow(mysql_result).to receive(:free)
      wrapper_result.free

      expect(plugin.sql_for('result.free')).to eq([sql])
    end
  end

  describe '#fields' do
    let(:connection) { instance_double(Mysql2::Client) }
    let(:container) { build_service_container_with_plugins([TrackingPlugin.new], connection) }
    # A statement is supplied to prove #fields ignores it and reads the result even so. The
    # statement's fields are always strings, so a symbol result here can only have come from the
    # result - which is where mysql2 applies options such as symbolize_keys.
    let(:statement) { double('Mysql2::Statement', fields: %w[ssn]) }

    it 'reads the result rather than the statement' do
      result = double('Mysql2::Result', fields: %i[ssn])

      wrapper_result = described_class.new(result, container, connection, nil, statement)

      expect(wrapper_result.fields).to eq(%i[ssn])
    end

    it 'surfaces an error from a freed result instead of masking it with the statement' do
      result = double('Mysql2::Result')
      allow(result).to receive(:fields).and_raise(Mysql2::Error, 'Result set has already been freed')

      wrapper_result = described_class.new(result, container, connection, nil, statement)

      expect { wrapper_result.fields }.to raise_error(Mysql2::Error, /already been freed/)
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

  describe '#method_missing' do
    let(:result) { double('Mysql2::Result') }
    let(:connection) { double('Mysql2::Client') }
    subject(:wrapper_result) do
      described_class.new(result, build_service_container_with_plugins([], connection), connection)
    end

    context 'when the method exists on the underlying result but is not explicitly delegated' do
      before do
        allow(result).to receive(:respond_to?).and_return(false)
        allow(result).to receive(:respond_to?).with(:undelegated_method).and_return(true)
        allow(result).to receive(:respond_to?).with(:undelegated_method, false).and_return(true)
        allow(result).to receive(:undelegated_method).and_return(:delegated)
      end

      it 'delegates transparently to the underlying result' do
        expect(wrapper_result.undelegated_method).to eq(:delegated)
      end

      it 'returns true from respond_to?' do
        expect(wrapper_result.respond_to?(:undelegated_method)).to be true
      end
    end

    context 'when the method does not exist on the underlying result either' do
      before { allow(result).to receive(:respond_to?).and_return(false) }

      it 'raises a NoMethodError' do
        expect { wrapper_result.nonexistent_method }.to raise_error(NoMethodError)
      end

      it 'returns false from respond_to?' do
        expect(wrapper_result.respond_to?(:nonexistent_method)).to be false
      end
    end
  end
end
