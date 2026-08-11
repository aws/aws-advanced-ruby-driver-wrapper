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

# The SQL a statement was made with is not always among the arguments of the call that a plugin sees:
# a prepared statement is executed with its parameters alone, and an asynchronous result is read by a
# call of its own. The client publishes it separately, so that a plugin which has to inspect the
# statement can still read it.
RSpec.describe AwsRubyDatabaseDriverWrapper::Mysql2WrapperClient do
  let(:mysql_result) { driver_result(Mysql2::Result, 'Mysql2::Result') }
  let(:connection) { double('Mysql2::Client') }
  let(:recorded) { build_recording_container(connection) }
  let(:container) { recorded.first }
  let(:plugin) { recorded.last }
  subject(:client) do
    client = described_class.allocate
    client.instance_variable_set(:@service_container, container)
    client.instance_variable_set(:@async_conn, nil)
    client.instance_variable_set(:@async_sql, nil)
    client
  end

  describe '#query' do
    it 'publishes the SQL it was called with' do
      allow(connection).to receive(:query).and_return(mysql_result)
      client.query('SELECT ssn FROM users')

      expect(plugin.sql_for('connection.query')).to eq(['SELECT ssn FROM users'])
    end

    # The rows are read after the call that produced them has returned, so the result has to carry
    # the statement's SQL with it.
    it 'hands the SQL to the result it returns' do
      allow(connection).to receive(:query).and_return(mysql_result)
      allow(mysql_result).to receive(:to_a).and_return([])

      client.query('SELECT ssn FROM users').to_a

      expect(plugin.sql_for('result.to_a')).to eq(['SELECT ssn FROM users'])
    end
  end

  describe '#prepare' do
    it 'publishes the SQL it was called with' do
      allow(connection).to receive(:prepare).and_return(double('Mysql2::Statement'))
      client.prepare('INSERT INTO users (name, ssn) VALUES (?, ?)')

      expect(plugin.sql_for('connection.prepare')).to eq(['INSERT INTO users (name, ssn) VALUES (?, ?)'])
    end

    # This is the whole reason the SQL is remembered: execute is called with parameters alone.
    it 'hands the SQL to the statement it returns' do
      mysql_stmt = double('Mysql2::Statement')
      allow(connection).to receive(:prepare).and_return(mysql_stmt)
      allow(mysql_stmt).to receive(:execute).and_return(mysql_result)

      client.prepare('INSERT INTO users (name, ssn) VALUES (?, ?)').execute('Jo', '123-45-6789')

      expect(plugin.sql_for('statement.execute')).to eq(['INSERT INTO users (name, ssn) VALUES (?, ?)'])
    end
  end

  describe 'an asynchronous statement' do
    before do
      allow(connection).to receive(:query_async).and_return(nil)
      allow(connection).to receive(:store_result).and_return(mysql_result)
    end

    it 'publishes the SQL it was sent with' do
      client.query_async('SELECT ssn FROM users')

      expect(plugin.sql_for('connection.query_async')).to eq(['SELECT ssn FROM users'])
    end

    # store_result is a call of its own, made after the statement was sent.
    it 'publishes the SQL that was sent when the result is stored' do
      client.query_async('SELECT ssn FROM users')
      client.store_result

      expect(plugin.sql_for('connection.store_result')).to eq(['SELECT ssn FROM users'])
    end

    it 'hands the SQL that was sent to the result it stores' do
      allow(mysql_result).to receive(:to_a).and_return([])

      client.query_async('SELECT ssn FROM users')
      client.store_result.to_a

      expect(plugin.sql_for('result.to_a')).to eq(['SELECT ssn FROM users'])
    end

    # The SQL of a statement that is already finished must not be published for whatever is read
    # next.
    it 'forgets the SQL once the result has been stored' do
      client.query_async('SELECT ssn FROM users')
      client.store_result
      client.store_result

      expect(plugin.sql_for('connection.store_result')).to eq(['SELECT ssn FROM users', nil])
    end
  end

  # Nothing else in the call chain has any SQL to publish.
  describe 'a call that has no SQL of its own' do
    it 'publishes no SQL' do
      allow(connection).to receive(:ping).and_return(true)
      client.ping

      expect(plugin.sql_for('connection.ping')).to eq([nil])
    end
  end
end
