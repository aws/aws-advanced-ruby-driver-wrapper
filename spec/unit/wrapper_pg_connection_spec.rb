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
require 'aws_ruby_database_driver_wrapper/driver_dialects/pg_driver_dialect'
require 'aws_ruby_database_driver_wrapper/services/plugin_manager'
require 'aws_ruby_database_driver_wrapper/services/service_container'

# The SQL a statement was made with is not always among the arguments of the call that a plugin
# sees: a prepared statement carries only the name it was prepared under, and an asynchronous result
# is read by a call of its own. The connection publishes it separately, so that a plugin which has
# to inspect the statement can still read it.
RSpec.describe AwsRubyDatabaseDriverWrapper::WrapperPgConnection do
  let(:pg_result) { driver_result(PG::Result, 'PgResult') }
  let(:connection) { double('PgConnection') }
  let(:recorded) { build_recording_container(connection) }
  let(:container) { recorded.first }
  let(:plugin) { recorded.last }
  subject(:wrapper) do
    wrapper = described_class.allocate
    wrapper.instance_variable_set(:@service_container, container)
    wrapper.instance_variable_set(:@prepared_on, {})
    wrapper.instance_variable_set(:@prepared_sql, {})
    wrapper.instance_variable_set(:@async_conn, nil)
    wrapper.instance_variable_set(:@async_sql, nil)
    wrapper.instance_variable_set(:@copy_conn, nil)
    wrapper.instance_variable_set(:@lo_conn, nil)
    # Which methods go through the pipeline is the dialect's answer, and it is memoized here, so it
    # is set rather than reached for through a service container that is not connected to anything.
    wrapper.instance_variable_set(
      :@network_bound_methods, AwsRubyDatabaseDriverWrapper::DriverDialects::PgDriverDialect::NETWORK_BOUND_METHODS
    )
    wrapper
  end

  describe '#exec' do
    it 'publishes the SQL it was called with' do
      allow(connection).to receive(:exec).and_return(pg_result)
      wrapper.exec('SELECT ssn FROM users')

      expect(plugin.sql_for('connection.exec')).to eq(['SELECT ssn FROM users'])
    end

    # The rows are read after the call that produced them has returned, so the result has to carry
    # the statement's SQL with it.
    it 'hands the SQL to the result it returns' do
      allow(connection).to receive(:exec).and_return(pg_result)
      allow(pg_result).to receive(:to_a).and_return([])

      wrapper.exec('SELECT ssn FROM users').to_a

      expect(plugin.sql_for('result.to_a')).to eq(['SELECT ssn FROM users'])
    end
  end

  describe '#exec_params' do
    it 'publishes the SQL it was called with' do
      allow(connection).to receive(:exec_params).and_return(pg_result)
      wrapper.exec_params('SELECT ssn FROM users WHERE name = $1', ['Jo'])

      expect(plugin.sql_for('connection.exec_params')).to eq(['SELECT ssn FROM users WHERE name = $1'])
    end

    it 'hands the SQL to the result it returns' do
      allow(connection).to receive(:exec_params).and_return(pg_result)
      allow(pg_result).to receive(:to_a).and_return([])

      wrapper.exec_params('SELECT ssn FROM users WHERE name = $1', ['Jo']).to_a

      expect(plugin.sql_for('result.to_a')).to eq(['SELECT ssn FROM users WHERE name = $1'])
    end
  end

  describe '#async_exec' do
    it 'publishes the SQL it was called with' do
      allow(connection).to receive(:async_exec).and_return(pg_result)
      wrapper.async_exec('SELECT ssn FROM users')

      expect(plugin.sql_for('connection.async_exec')).to eq(['SELECT ssn FROM users'])
    end
  end

  describe 'a prepared statement' do
    before do
      allow(connection).to receive(:prepare)
      allow(connection).to receive(:exec_prepared).and_return(pg_result)
      allow(connection).to receive(:describe_prepared).and_return(pg_result)
      wrapper.prepare('insert_user', 'INSERT INTO users (name, ssn) VALUES ($1, $2)')
    end

    it 'publishes the SQL when it is prepared' do
      expect(plugin.sql_for('connection.prepare')).to eq(['INSERT INTO users (name, ssn) VALUES ($1, $2)'])
    end

    # This is the whole reason the SQL is remembered: exec_prepared is called with a statement name.
    it 'publishes the SQL it was prepared with when it is executed' do
      wrapper.exec_prepared('insert_user', %w[Jo 123-45-6789])

      expect(plugin.sql_for('connection.exec_prepared')).to eq(['INSERT INTO users (name, ssn) VALUES ($1, $2)'])
    end

    it 'publishes the SQL it was prepared with when it is described' do
      wrapper.describe_prepared('insert_user')

      expect(plugin.sql_for('connection.describe_prepared')).to eq(['INSERT INTO users (name, ssn) VALUES ($1, $2)'])
    end

    it 'hands the SQL it was prepared with to the result of executing it' do
      allow(pg_result).to receive(:to_a).and_return([])
      wrapper.exec_prepared('insert_user', %w[Jo 123-45-6789]).to_a

      expect(plugin.sql_for('result.to_a')).to eq(['INSERT INTO users (name, ssn) VALUES ($1, $2)'])
    end

    it 'keeps the SQL of every statement that was prepared' do
      wrapper.prepare('select_user', 'SELECT ssn FROM users WHERE name = $1')

      wrapper.exec_prepared('select_user', ['Jo'])
      wrapper.exec_prepared('insert_user', %w[Jo 123-45-6789])

      expect(plugin.sql_for('connection.exec_prepared'))
        .to eq(['SELECT ssn FROM users WHERE name = $1', 'INSERT INTO users (name, ssn) VALUES ($1, $2)'])
    end

    it 'has no SQL for a statement it never prepared' do
      wrapper.exec_prepared('prepared_elsewhere', ['Jo'])

      expect(plugin.sql_for('connection.exec_prepared')).to eq([nil])
    end

    it 'publishes the SQL it was prepared with when it is sent asynchronously and read back' do
      allow(connection).to receive(:send_query_prepared)
      allow(connection).to receive(:get_result).and_return(pg_result)

      wrapper.send_query_prepared('insert_user', %w[Jo 123-45-6789])
      wrapper.get_result

      expect(plugin.sql_for('connection.send_query_prepared')).to eq(['INSERT INTO users (name, ssn) VALUES ($1, $2)'])
      expect(plugin.sql_for('connection.get_result')).to eq(['INSERT INTO users (name, ssn) VALUES ($1, $2)'])
    end
  end

  describe 'an asynchronous statement' do
    before do
      allow(connection).to receive(:send_query)
      allow(connection).to receive(:send_query_params)
      allow(connection).to receive(:get_result).and_return(pg_result)
      allow(connection).to receive(:get_last_result).and_return(pg_result)
    end

    # get_result and get_last_result are calls of their own, made after the statement was sent.
    it 'publishes the SQL that was sent when the result is read' do
      wrapper.send_query('SELECT ssn FROM users')
      wrapper.get_result

      expect(plugin.sql_for('connection.send_query')).to eq(['SELECT ssn FROM users'])
      expect(plugin.sql_for('connection.get_result')).to eq(['SELECT ssn FROM users'])
    end

    it 'publishes the SQL that was sent with parameters when the last result is read' do
      wrapper.send_query_params('SELECT ssn FROM users WHERE name = $1', ['Jo'])
      wrapper.get_last_result

      expect(plugin.sql_for('connection.send_query_params')).to eq(['SELECT ssn FROM users WHERE name = $1'])
      expect(plugin.sql_for('connection.get_last_result')).to eq(['SELECT ssn FROM users WHERE name = $1'])
    end

    it 'hands the SQL that was sent to the result it returns' do
      allow(pg_result).to receive(:to_a).and_return([])

      wrapper.send_query('SELECT ssn FROM users')
      wrapper.get_result.to_a

      expect(plugin.sql_for('result.to_a')).to eq(['SELECT ssn FROM users'])
    end

    # A nil result means the statement is done with, and its SQL must not be published for whatever
    # is read next.
    it 'forgets the SQL once the statement has no more results' do
      allow(connection).to receive(:get_result).and_return(pg_result, nil, pg_result)

      wrapper.send_query('SELECT ssn FROM users')
      wrapper.get_result
      wrapper.get_result
      wrapper.get_result

      expect(plugin.sql_for('connection.get_result')).to eq(['SELECT ssn FROM users', 'SELECT ssn FROM users', nil])
    end

    it 'forgets the SQL once the last result has been read' do
      wrapper.send_query('SELECT ssn FROM users')
      wrapper.get_last_result
      wrapper.get_result

      expect(plugin.sql_for('connection.get_result')).to eq([nil])
    end
  end

  # pg gives most of its calls more than one spelling, and an application is free to use any of them.
  # A spelling this class does not define is performed by the method that does define the operation,
  # so that it publishes the same SQL and keeps the same bookkeeping. Before that, an unrecognized
  # spelling was handed straight to the driver, which took the statement it carried past every
  # plugin.
  describe 'the other spellings pg gives a call' do
    it 'publishes the SQL of query, which is the exec it is named for' do
      allow(connection).to receive(:query).and_return(pg_result)
      wrapper.query('INSERT INTO users (name, ssn) VALUES ($1, $2)', %w[Jo 123-45-6789])

      expect(plugin.sql_for('connection.exec')).to eq(['INSERT INTO users (name, ssn) VALUES ($1, $2)'])
    end

    it 'publishes the SQL of async_query' do
      allow(connection).to receive(:exec).and_return(pg_result)
      wrapper.async_query('SELECT ssn FROM users')

      expect(plugin.sql_for('connection.exec')).to eq(['SELECT ssn FROM users'])
    end

    it 'publishes the SQL of sync_exec_params' do
      allow(connection).to receive(:exec_params).and_return(pg_result)
      wrapper.sync_exec_params('SELECT ssn FROM users WHERE name = $1', ['Jo'])

      expect(plugin.sql_for('connection.exec_params')).to eq(['SELECT ssn FROM users WHERE name = $1'])
    end

    it 'performs the call it was given, once' do
      allow(connection).to receive(:exec).and_return(pg_result)
      wrapper.sync_exec('SELECT ssn FROM users')

      expect(connection).to have_received(:exec).with('SELECT ssn FROM users').once
    end

    it 'wraps the result of a spelling it translated' do
      allow(connection).to receive(:exec_params).and_return(pg_result)
      allow(pg_result).to receive(:to_a).and_return([])

      wrapper.async_exec_params('SELECT ssn FROM users WHERE name = $1', ['Jo']).to_a

      expect(plugin.sql_for('result.to_a')).to eq(['SELECT ssn FROM users WHERE name = $1'])
    end

    # The statement was prepared by one spelling and executed by another, and the SQL has to survive
    # the trip either way.
    it 'publishes the SQL a statement was prepared with under any spelling' do
      allow(connection).to receive(:prepare)
      allow(connection).to receive(:exec_prepared).and_return(pg_result)

      wrapper.sync_prepare('insert_user', 'INSERT INTO users (name, ssn) VALUES ($1, $2)')
      wrapper.async_exec_prepared('insert_user', %w[Jo 123-45-6789])

      expect(plugin.sql_for('connection.exec_prepared')).to eq(['INSERT INTO users (name, ssn) VALUES ($1, $2)'])
    end

    it 'says it responds to the spellings it translates' do
      expect(wrapper).to respond_to(:sync_exec, :async_exec_params, :notifies_wait, :loread)
    end
  end

  # These are the calls that were left to method_missing because an application rarely makes them.
  # They still talk to the server, so they still go through the plugins, and they are entered under
  # the name the pipeline knows them by so that the connection they belong to is checked.
  describe 'a network call that has no method of its own' do
    it 'goes through the pipeline' do
      allow(connection).to receive(:close_prepared)
      wrapper.close_prepared('insert_user')

      expect(plugin.method_names).to eq(['connection.close_prepared'])
    end

    it 'publishes the SQL of the statement it names' do
      allow(connection).to receive(:prepare)
      allow(connection).to receive(:close_prepared)

      wrapper.prepare('insert_user', 'INSERT INTO users (name, ssn) VALUES ($1, $2)')
      wrapper.close_prepared('insert_user')

      expect(plugin.sql_for('connection.close_prepared')).to eq(['INSERT INTO users (name, ssn) VALUES ($1, $2)'])
    end

    it 'forgets a statement it closed' do
      allow(connection).to receive(:prepare)
      allow(connection).to receive(:close_prepared)
      allow(connection).to receive(:exec_prepared).and_return(pg_result)

      wrapper.prepare('insert_user', 'INSERT INTO users (name, ssn) VALUES ($1, $2)')
      wrapper.close_prepared('insert_user')
      wrapper.exec_prepared('insert_user')

      expect(plugin.sql_for('connection.exec_prepared')).to eq([nil])
    end

    # The statement only exists on the connection it was prepared on, which is the whole reason the
    # call is entered under a name the pipeline knows rather than as a bare string.
    it 'is refused when the statement it names belongs to another connection' do
      wrapper.instance_variable_set(:@prepared_on, { 'insert_user' => double('OldConnection') })
      allow(connection).to receive(:close_prepared)

      expect { wrapper.close_prepared('insert_user') }
        .to raise_error(AwsRubyDatabaseDriverWrapper::Errors::AwsError, /old connection/)
    end

    it 'is refused when a large object was opened on another connection' do
      wrapper.instance_variable_set(:@lo_conn, double('OldConnection'))
      allow(connection).to receive(:lo_read)

      expect { wrapper.loread(0, 4) }.to raise_error(AwsRubyDatabaseDriverWrapper::Errors::AwsError, /old connection/)
    end

    it 'allows a large object read on the connection it was opened on' do
      allow(connection).to receive(:lo_open).and_return(0)
      allow(connection).to receive(:lo_read).and_return('data')

      wrapper.lo_open(1234)

      expect(wrapper.loread(0, 4)).to eq('data')
      expect(plugin.method_names).to eq(['connection.lo_open', 'connection.lo_read'])
    end

    it 'reads the results of a description it sent asynchronously' do
      allow(connection).to receive(:prepare)
      allow(connection).to receive(:send_describe_prepared)
      allow(connection).to receive(:get_result).and_return(pg_result)

      wrapper.prepare('insert_user', 'INSERT INTO users (name, ssn) VALUES ($1, $2)')
      wrapper.send_describe_prepared('insert_user')
      wrapper.get_result

      expect(plugin.sql_for('connection.get_result')).to eq(['INSERT INTO users (name, ssn) VALUES ($1, $2)'])
    end

    it 'hands a call that does not talk to the server straight to the driver' do
      allow(connection).to receive(:escape_string).and_return('Jo')

      expect(wrapper.escape_string('Jo')).to eq('Jo')
      expect(plugin.method_names).to be_empty
    end
  end

  # Nothing else in the call chain has any SQL to publish, and a plugin that inspects statements
  # must not be handed the SQL of a statement that is already finished.
  describe 'a call that has no SQL of its own' do
    it 'publishes no SQL' do
      allow(connection).to receive(:ping).and_return(true)
      wrapper.ping

      expect(plugin.sql_for('connection.ping')).to eq([nil])
    end
  end
end
