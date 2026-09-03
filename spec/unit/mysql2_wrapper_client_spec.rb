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
require 'aws_advanced_ruby_driver_wrapper/driver_dialects/mysql_driver_dialect'
require 'aws_advanced_ruby_driver_wrapper/services/plugin_manager'
require 'aws_advanced_ruby_driver_wrapper/services/service_container'

# Every call that talks to the server has to reach the plugins under a name mysql2 answers to, and a
# call that can only be made on the connection a statement was sent on has to be refused anywhere
# else.
#
# The SQL a statement was made with is not always among the arguments of the call that a plugin sees
# either: a prepared statement is executed with its parameters alone, and an asynchronous result is
# read by a call of its own. The client publishes it separately, so that a plugin which has to inspect
# the statement can still read it.
RSpec.describe AwsAdvancedRubyDriverWrapper::Mysql2WrapperClient do
  let(:mysql_result) { driver_result(Mysql2::Result, 'Mysql2::Result') }
  # A verifying double, so that a call the wrapper makes on a method mysql2 does not define fails
  # here rather than against a real server.
  let(:connection) { instance_double(Mysql2::Client) }
  let(:recorded) { build_recording_container(connection) }
  let(:container) { recorded.first }
  let(:plugin) { recorded.last }
  subject(:client) do
    client = described_class.allocate
    client.instance_variable_set(:@service_container, container)
    client.instance_variable_set(:@async_conn, nil)
    client.instance_variable_set(:@async_sql, nil)
    client.instance_variable_set(:@last_sql, nil)
    # Which methods go through the pipeline is the dialect's answer, and it is memoized here, so it is
    # set rather than reached for through a service container that is not connected to anything.
    client.instance_variable_set(
      :@network_bound_methods, AwsAdvancedRubyDriverWrapper::DriverDialects::MysqlDriverDialect::NETWORK_BOUND_METHODS
    )
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
      allow(connection).to receive(:prepare).and_return(instance_double(Mysql2::Statement))
      client.prepare('INSERT INTO users (name, ssn) VALUES (?, ?)')

      expect(plugin.sql_for('connection.prepare')).to eq(['INSERT INTO users (name, ssn) VALUES (?, ?)'])
    end

    # This is the whole reason the SQL is remembered: execute is called with parameters alone.
    it 'hands the SQL to the statement it returns' do
      mysql_stmt = instance_double(Mysql2::Statement)
      allow(connection).to receive(:prepare).and_return(mysql_stmt)
      allow(mysql_stmt).to receive(:execute).and_return(mysql_result)

      client.prepare('INSERT INTO users (name, ssn) VALUES (?, ?)').execute('Jo', '123-45-6789')

      expect(plugin.sql_for('statement.execute')).to eq(['INSERT INTO users (name, ssn) VALUES (?, ?)'])
    end
  end

  # mysql2 has no query_async: a statement is sent asynchronously by passing async: true to query, and
  # its result is read afterwards by async_result. The client used to call query_async, which mysql2
  # does not define, so an asynchronous statement raised NoMethodError instead of being sent.
  describe 'an asynchronous statement' do
    before do
      allow(connection).to receive(:query).and_return(nil)
      allow(connection).to receive(:async_result).and_return(mysql_result)
    end

    it 'is sent by the query it is an option of' do
      client.query('SELECT ssn FROM users', async: true)

      expect(connection).to have_received(:query).with('SELECT ssn FROM users', { async: true })
      expect(plugin.method_names).to eq(['connection.query'])
    end

    it 'publishes the SQL it was sent with' do
      client.query('SELECT ssn FROM users', async: true)

      expect(plugin.sql_for('connection.query')).to eq(['SELECT ssn FROM users'])
    end

    # async_result is a call of its own, made after the statement was sent, so it takes the connection
    # the statement was sent on, and the SQL that was sent, from the client rather than from its
    # arguments.
    it 'reads its result through the pipeline' do
      client.query('SELECT ssn FROM users', async: true)
      client.async_result

      expect(plugin.method_names).to eq(['connection.query', 'connection.async_result'])
    end

    it 'publishes the SQL that was sent when the result is read' do
      client.query('SELECT ssn FROM users', async: true)
      client.async_result

      expect(plugin.sql_for('connection.async_result')).to eq(['SELECT ssn FROM users'])
    end

    it 'wraps the result it reads' do
      allow(mysql_result).to receive(:to_a).and_return([])

      client.query('SELECT ssn FROM users', async: true)
      client.async_result.to_a

      expect(plugin.method_names).to eq(['connection.query', 'connection.async_result', 'result.to_a'])
    end

    it 'hands the SQL that was sent to the result it reads' do
      allow(mysql_result).to receive(:to_a).and_return([])

      client.query('SELECT ssn FROM users', async: true)
      client.async_result.to_a

      expect(plugin.sql_for('result.to_a')).to eq(['SELECT ssn FROM users'])
    end

    # The result is only waiting on the connection the statement was sent on.
    it 'is refused on any other connection' do
      client.instance_variable_set(:@async_conn, instance_double(Mysql2::Client))

      expect { client.async_result }
        .to raise_error(AwsAdvancedRubyDriverWrapper::Errors::AwsError, /old connection/)
    end

    it 'forgets the connection once the result has been read' do
      client.query('SELECT ssn FROM users', async: true)
      client.async_result

      expect(client.instance_variable_get(:@async_conn)).to be_nil
    end

    # The SQL of a statement that is already finished must not be published for whatever is read next.
    it 'forgets the SQL once the result has been read' do
      client.query('SELECT ssn FROM users', async: true)
      client.async_result
      client.async_result

      expect(plugin.sql_for('connection.async_result')).to eq(['SELECT ssn FROM users', nil])
    end

    it 'remembers no connection for a synchronous statement, which is read when it is made' do
      allow(connection).to receive(:query).and_return(mysql_result)

      client.query('SELECT ssn FROM users')

      expect(client.instance_variable_get(:@async_conn)).to be_nil
    end

    it 'publishes no SQL for a synchronous statement, which is read when it is made' do
      allow(connection).to receive(:query).and_return(mysql_result)
      allow(connection).to receive(:store_result).and_return(mysql_result)

      client.query('SELECT ssn FROM users')
      client.store_result

      expect(plugin.sql_for('connection.store_result')).to eq([nil])
    end
  end

  describe 'a statement that leaves more than one result set' do
    before do
      allow(connection).to receive(:query).and_return(mysql_result)
      allow(connection).to receive(:store_result).and_return(mysql_result)
    end

    it 'takes every result set it stores through the pipeline' do
      allow(connection).to receive(:next_result).and_return(true, true, false)

      client.query('CALL two_selects()')
      client.next_result
      client.store_result
      client.next_result
      client.store_result

      expect(plugin.method_names).to eq(
        ['connection.query', 'connection.next_result', 'connection.store_result',
         'connection.next_result', 'connection.store_result']
      )
    end

    it 'publishes its SQL for every result set that is read' do
      allow(connection).to receive(:next_result).and_return(true, true, false)

      client.query('CALL two_selects()')
      client.next_result
      client.store_result
      client.next_result
      client.store_result

      expect(plugin.sql_for('connection.store_result')).to eq(['CALL two_selects()', 'CALL two_selects()'])
    end

    it 'puts the connection back for the read that follows each result set' do
      allow(connection).to receive(:next_result).and_return(true)

      client.query('CALL two_selects()')
      client.store_result
      client.next_result

      expect(client.instance_variable_get(:@async_conn)).to eq(connection)
    end

    it 'forgets the connection once there is nothing left to read' do
      allow(connection).to receive(:next_result).and_return(false)

      client.query('CALL two_selects()')
      client.next_result

      expect(client.instance_variable_get(:@async_conn)).to be_nil
    end

    it 'forgets the SQL once there is nothing left to read' do
      allow(connection).to receive(:next_result).and_return(true, false)

      client.query('CALL two_selects()')
      client.next_result
      client.next_result
      client.store_result

      expect(plugin.sql_for('connection.store_result')).to eq([nil])
    end

    # mysql2 spells this with a question mark and has no more_results, so the wrapper called a method
    # the driver does not define and the dialect named an entry nothing could ever match.
    it 'answers whether more results are pending' do
      allow(connection).to receive(:more_results?).and_return(true)

      expect(client.more_results?).to be(true)
      expect(plugin.method_names).to eq(['connection.more_results?'])
    end
  end

  # These are the calls that were left to method_missing because an application rarely makes them.
  # They still talk to the server, so they still go through the plugins, and they are entered under
  # the name the pipeline knows them by so that the connection they belong to is checked.
  describe 'a network call that has no method of its own' do
    it 'drains what is left of a statement through the pipeline' do
      allow(connection).to receive(:query).and_return(nil)
      allow(connection).to receive(:abandon_results!)

      client.query('SELECT ssn FROM users', async: true)
      client.abandon_results!

      expect(plugin.method_names).to eq(['connection.query', 'connection.abandon_results!'])
      expect(client.instance_variable_get(:@async_conn)).to be_nil
      expect(client.instance_variable_get(:@async_sql)).to be_nil
    end

    it 'refuses to drain a connection the statement was not sent on' do
      client.instance_variable_set(:@async_conn, instance_double(Mysql2::Client))
      allow(connection).to receive(:abandon_results!)

      expect { client.abandon_results! }
        .to raise_error(AwsAdvancedRubyDriverWrapper::Errors::AwsError, /old connection/)
    end

    it 'sends a server option through the pipeline' do
      allow(connection).to receive(:set_server_option).and_return(true)

      client.set_server_option(0)

      expect(plugin.method_names).to eq(['connection.set_server_option'])
    end

    it 'hands a call that does not talk to the server straight to the driver' do
      allow(connection).to receive(:affected_rows).and_return(1)

      expect(client.affected_rows).to eq(1)
      expect(plugin.method_names).to be_empty
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
