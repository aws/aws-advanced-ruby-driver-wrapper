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
require 'aws_ruby_database_driver_wrapper/postgresql'
require 'aws_ruby_database_driver_wrapper/services/plugin_manager'
require 'aws_ruby_database_driver_wrapper/services/service_container'

# The rows are read after the call that produced them has returned, so a plugin which has to know
# which columns a row holds can only learn it from the SQL the result carries.
RSpec.describe AwsRubyDatabaseDriverWrapper::WrapperPgResult do
  let(:sql) { 'SELECT ssn FROM users' }
  let(:pg_result) { double('PG::Result') }
  let(:connection) { double('PgConnection') }
  let(:recorded) { build_recording_container(connection) }
  let(:container) { recorded.first }
  let(:plugin) { recorded.last }
  subject(:result) { described_class.new(pg_result, container, connection, sql) }

  it 'publishes the SQL of the statement when the rows are iterated' do
    allow(pg_result).to receive(:each)
    result.each { |row| row }

    expect(plugin.sql_for('result.each')).to eq([sql])
  end

  it 'publishes the SQL of the statement when the rows are iterated as arrays' do
    allow(pg_result).to receive(:each_row)
    result.each_row { |row| row }

    expect(plugin.sql_for('result.each_row')).to eq([sql])
  end

  it 'publishes the SQL of the statement when the rows are collected' do
    allow(pg_result).to receive(:to_a).and_return([])
    result.to_a

    expect(plugin.sql_for('result.to_a')).to eq([sql])
  end

  it 'publishes the SQL of the statement when a single row is read' do
    allow(pg_result).to receive(:[]).and_return({})
    result[0]

    expect(plugin.sql_for('result.[]')).to eq([sql])
  end

  it 'publishes the SQL of the statement when the values are read' do
    allow(pg_result).to receive(:values).and_return([])
    result.values

    expect(plugin.sql_for('result.values')).to eq([sql])
  end

  it 'publishes the SQL of the statement when a column is read' do
    allow(pg_result).to receive(:column_values).and_return([])
    result.column_values(0)

    expect(plugin.sql_for('result.column_values')).to eq([sql])
  end

  it 'publishes the SQL of the statement when a field is read' do
    allow(pg_result).to receive(:field_values).and_return([])
    result.field_values('ssn')

    expect(plugin.sql_for('result.field_values')).to eq([sql])
  end

  it 'publishes the SQL of the statement when a tuple is read' do
    allow(pg_result).to receive(:tuple).and_return({})
    result.tuple(0)

    expect(plugin.sql_for('result.tuple')).to eq([sql])
  end

  it 'publishes the SQL of the statement for every read of the same result' do
    allow(pg_result).to receive(:to_a).and_return([])
    result.to_a
    result.to_a

    expect(plugin.sql_for('result.to_a')).to eq([sql, sql])
  end

  # A result built by a call whose SQL the wrapper does not know, such as one that went through
  # method_missing, publishes nothing rather than the SQL of some other statement.
  it 'publishes no SQL when it was built without any' do
    allow(pg_result).to receive(:to_a).and_return([])
    described_class.new(pg_result, container, connection).to_a

    expect(plugin.sql_for('result.to_a')).to eq([nil])
  end
end
