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

# Every call that talks to the server has to reach the plugins, and a call that can only be made on
# the connection an earlier one left something on has to be refused anywhere else. pg gives most of
# its calls more than one spelling and has more of them than are worth a method each, so the two are
# what this covers.
#
# The SQL a statement was made with is not always among the arguments of the call that a plugin sees
# either: a prepared statement carries only the name it was prepared under, and an asynchronous result
# is read by a call of its own. The connection publishes it separately, so that a plugin which has to
# inspect the statement can still read it.
RSpec.describe AwsRubyDatabaseDriverWrapper::WrapperPgConnection do
  let(:pg_result) { driver_result(PG::Result, 'PgResult') }
  # A verifying double, so that a call the wrapper makes on a method pg does not define fails here
  # rather than against a real server.
  let(:connection) { instance_double(PG::Connection) }
  let(:recorded) { build_recording_container(connection) }
  let(:container) { recorded.first }
  let(:plugin) { recorded.last }
  subject(:wrapper) { build_wrapper(container) }

  # The state initialize would have left, without connecting to anything.
  def build_wrapper(container)
    wrapper = described_class.allocate
    wrapper.instance_variable_set(:@service_container, container)
    wrapper.instance_variable_set(:@prepared_on, {})
    wrapper.instance_variable_set(:@prepared_sql, {})
    wrapper.instance_variable_set(:@async_conn, nil)
    wrapper.instance_variable_set(:@async_sql, nil)
    wrapper.instance_variable_set(:@copy_conn, nil)
    wrapper.instance_variable_set(:@copy_sql, nil)
    wrapper.instance_variable_set(:@lo_conn, nil)
    # Which methods go through the pipeline is the dialect's answer, and it is memoized here, so it is
    # set rather than reached for through a service container that is not connected to anything.
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

  # A statement can be prepared by sending a PREPARE instead of by calling prepare, and the
  # exec_prepared that runs it looks the same either way, so the SQL has to be remembered either way
  # as well: a plugin reading the statement an exec_prepared runs has nowhere else to get it from.
  describe 'a statement prepared by a PREPARE' do
    before do
      allow(connection).to receive(:exec).and_return(pg_result)
      allow(connection).to receive(:exec_prepared).and_return(pg_result)
    end

    it 'publishes the prepared statement when it is executed' do
      wrapper.exec('PREPARE insert_user AS INSERT INTO users (name, ssn) VALUES ($1, $2)')
      wrapper.exec_prepared('insert_user', %w[Jo 123-45-6789])

      expect(plugin.sql_for('connection.exec_prepared')).to eq(['INSERT INTO users (name, ssn) VALUES ($1, $2)'])
    end

    it 'reads a PREPARE whichever way it was written' do
      [
        ['one', 'PREPARE one (text, text) AS INSERT INTO users (name, ssn) VALUES ($1, $2)'],
        ['two', "  prepare\n  two\n  as\n  INSERT INTO users (name, ssn) VALUES ($1, $2)"],
        ['three', 'PREPARE "three" AS INSERT INTO users (name, ssn) VALUES ($1, $2)']
      ].each do |name, sql|
        wrapper.exec(sql)
        wrapper.exec_prepared(name, %w[Jo 123-45-6789])

        expect(plugin.sql_for('connection.exec_prepared').last)
          .to eq('INSERT INTO users (name, ssn) VALUES ($1, $2)'), sql
      end
    end

    # A statement prepared this way is named by an identifier, so an unquoted name is folded to lower
    # case, and the folded name is the one an exec_prepared has to give.
    it 'remembers an unquoted name folded to lower case' do
      wrapper.exec('PREPARE InsertUser AS INSERT INTO users (name, ssn) VALUES ($1, $2)')

      expect(wrapper.instance_variable_get(:@prepared_sql).keys).to eq(['insertuser'])
    end

    it 'remembers a quoted name as it was written' do
      wrapper.exec('PREPARE "InsertUser" AS INSERT INTO users (name, ssn) VALUES ($1, $2)')

      expect(wrapper.instance_variable_get(:@prepared_sql).keys).to eq(['InsertUser'])
    end

    it 'binds it to the connection it was prepared on, as prepare does' do
      wrapper.exec('PREPARE insert_user AS INSERT INTO users (name, ssn) VALUES ($1, $2)')

      expect(wrapper.instance_variable_get(:@prepared_on)['insert_user']).to eq(connection)
    end

    it 'leaves a statement that is not a PREPARE alone' do
      wrapper.exec('SELECT ssn FROM users')

      expect(wrapper.instance_variable_get(:@prepared_sql)).to be_empty
    end

    it 'forgets one that a DEALLOCATE un-prepares' do
      wrapper.exec('PREPARE insert_user AS INSERT INTO users (name, ssn) VALUES ($1, $2)')
      wrapper.exec('DEALLOCATE PREPARE insert_user')

      expect(wrapper.instance_variable_get(:@prepared_sql)).to be_empty
      expect(wrapper.instance_variable_get(:@prepared_on)).to be_empty
    end

    it 'forgets every statement that a DEALLOCATE ALL un-prepares' do
      wrapper.exec('PREPARE one AS INSERT INTO users (name, ssn) VALUES ($1, $2)')
      wrapper.exec('PREPARE two AS SELECT ssn FROM users WHERE name = $1')
      wrapper.exec('DEALLOCATE ALL')

      expect(wrapper.instance_variable_get(:@prepared_sql)).to be_empty
    end

    # ALL in quotes is a statement actually called ALL, and nothing else is un-prepared.
    it 'forgets only the statement a quoted ALL names' do
      wrapper.exec('PREPARE "ALL" AS SELECT 1')
      wrapper.exec('PREPARE two AS SELECT ssn FROM users WHERE name = $1')
      wrapper.exec('DEALLOCATE "ALL"')

      expect(wrapper.instance_variable_get(:@prepared_sql).keys).to eq(['two'])
    end

    it 'reads a PREPARE that was sent asynchronously' do
      allow(connection).to receive(:send_query)
      wrapper.send_query('PREPARE insert_user AS INSERT INTO users (name, ssn) VALUES ($1, $2)')
      wrapper.exec_prepared('insert_user', %w[Jo 123-45-6789])

      expect(plugin.sql_for('connection.exec_prepared')).to eq(['INSERT INTO users (name, ssn) VALUES ($1, $2)'])
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

  # The rows a COPY carries are named nowhere but the statement that opened it, and every call that
  # feeds or reads one is a call of its own, made after that statement was sent. That is why the
  # statement is held for as long as the block runs.
  describe 'a COPY' do
    let(:copy_sql) { 'COPY users (name, ssn) FROM STDIN' }

    before do
      allow(connection).to receive(:copy_data).and_yield
      allow(connection).to receive(:put_copy_data)
      allow(connection).to receive(:get_copy_data)
      allow(connection).to receive(:put_copy_end)
    end

    it 'publishes the statement it was opened with' do
      wrapper.copy_data(copy_sql) { nil }

      expect(plugin.sql_for('connection.copy_data')).to eq([copy_sql])
    end

    it 'publishes that statement for every row that is fed' do
      wrapper.copy_data(copy_sql) do
        wrapper.put_copy_data("Jo\t123-45-6789\n")
        wrapper.put_copy_data("Al\t987-65-4321\n")
      end

      expect(plugin.sql_for('connection.put_copy_data')).to eq([copy_sql, copy_sql])
    end

    it 'publishes that statement for every row that is read' do
      wrapper.copy_data('COPY users TO STDOUT') { wrapper.get_copy_data }

      expect(plugin.sql_for('connection.get_copy_data')).to eq(['COPY users TO STDOUT'])
    end

    # A statement that is done with must not be published for whatever is fed or read next.
    it 'forgets the statement once the COPY is over' do
      wrapper.copy_data(copy_sql) { nil }
      wrapper.put_copy_data("Jo\t123-45-6789\n")

      expect(plugin.sql_for('connection.put_copy_data')).to eq([nil])
    end

    it 'forgets the statement once its end has been sent' do
      wrapper.copy_data(copy_sql) { wrapper.put_copy_end }

      expect(wrapper.instance_variable_get(:@copy_sql)).to be_nil
    end

    it 'forgets the statement even when the block raises' do
      expect { wrapper.copy_data(copy_sql) { raise 'no' } }.to raise_error('no')

      expect(wrapper.instance_variable_get(:@copy_sql)).to be_nil
    end
  end

  # pg gives most of its calls more than one spelling, and an application is free to use any of them.
  # A spelling this class does not define is performed by the method that does define the operation,
  # so that it enters the pipeline under the same name, publishes the same SQL and keeps the same
  # bookkeeping. Before that, an unrecognized spelling was handed straight to the driver, which took
  # the statement it carried past every plugin.
  describe 'the other spellings pg gives a call' do
    it 'takes query through the pipeline as the exec it is named for' do
      allow(connection).to receive(:query).and_return(pg_result)
      wrapper.query('INSERT INTO users (name, ssn) VALUES ($1, $2)', %w[Jo 123-45-6789])

      expect(plugin.method_names).to eq(['connection.exec'])
    end

    it 'publishes the SQL of query, which is the exec it is named for' do
      allow(connection).to receive(:query).and_return(pg_result)
      wrapper.query('INSERT INTO users (name, ssn) VALUES ($1, $2)', %w[Jo 123-45-6789])

      expect(plugin.sql_for('connection.exec')).to eq(['INSERT INTO users (name, ssn) VALUES ($1, $2)'])
    end

    it 'takes async_query through the pipeline' do
      allow(connection).to receive(:async_query).and_return(pg_result)
      wrapper.async_query('SELECT ssn FROM users')

      expect(plugin.method_names).to eq(['connection.exec'])
    end

    it 'publishes the SQL of async_query' do
      allow(connection).to receive(:async_query).and_return(pg_result)
      wrapper.async_query('SELECT ssn FROM users')

      expect(plugin.sql_for('connection.exec')).to eq(['SELECT ssn FROM users'])
    end

    it 'takes sync_exec_params through the pipeline' do
      allow(connection).to receive(:sync_exec_params).and_return(pg_result)
      wrapper.sync_exec_params('SELECT ssn FROM users WHERE name = $1', ['Jo'])

      expect(plugin.method_names).to eq(['connection.exec_params'])
    end

    it 'publishes the SQL of sync_exec_params' do
      allow(connection).to receive(:sync_exec_params).and_return(pg_result)
      wrapper.sync_exec_params('SELECT ssn FROM users WHERE name = $1', ['Jo'])

      expect(plugin.sql_for('connection.exec_params')).to eq(['SELECT ssn FROM users WHERE name = $1'])
    end

    it 'performs the call it was given, once' do
      allow(connection).to receive(:sync_exec).and_return(pg_result)
      wrapper.sync_exec('SELECT ssn FROM users')

      expect(connection).to have_received(:sync_exec).with('SELECT ssn FROM users').once
    end

    it 'wraps the result of a spelling it translated' do
      allow(connection).to receive(:async_exec_params).and_return(pg_result)
      allow(pg_result).to receive(:to_a).and_return([])

      wrapper.async_exec_params('SELECT ssn FROM users WHERE name = $1', ['Jo']).to_a

      expect(plugin.method_names).to eq(['connection.exec_params', 'result.to_a'])
    end

    it 'hands the SQL of a spelling it translated to the result' do
      allow(connection).to receive(:async_exec_params).and_return(pg_result)
      allow(pg_result).to receive(:to_a).and_return([])

      wrapper.async_exec_params('SELECT ssn FROM users WHERE name = $1', ['Jo']).to_a

      expect(plugin.sql_for('result.to_a')).to eq(['SELECT ssn FROM users WHERE name = $1'])
    end

    # Only the pipeline name is shared. pg's sync_ forms are separate libpq calls rather than aliases:
    # sync_exec blocks in libpq and exec sends the statement and then waits on the socket from Ruby,
    # where the wait can be interrupted. Performing one as the other would be choosing for the caller.
    it 'asks the driver for the spelling it was given rather than the canonical one' do
      allow(connection).to receive(:sync_exec).and_return(pg_result)
      allow(connection).to receive(:exec).and_return(pg_result)

      wrapper.sync_exec('SELECT ssn FROM users')

      expect(connection).to have_received(:sync_exec)
      expect(connection).not_to have_received(:exec)
    end

    it 'asks the driver for the spelling of a call that has no method of its own' do
      allow(connection).to receive(:notifies_wait)
      allow(connection).to receive(:wait_for_notify)

      wrapper.notifies_wait(1)

      expect(connection).to have_received(:notifies_wait).with(1)
      expect(connection).not_to have_received(:wait_for_notify)
      expect(plugin.method_names).to eq(['connection.wait_for_notify'])
    end

    it 'goes back to the canonical spelling once a translated call is done' do
      allow(connection).to receive(:sync_exec).and_return(pg_result)
      allow(connection).to receive(:exec).and_return(pg_result)

      wrapper.sync_exec('SELECT ssn FROM users')
      wrapper.exec('SELECT ssn FROM users')

      expect(connection).to have_received(:sync_exec).once
      expect(connection).to have_received(:exec).once
    end

    # The statement was prepared by one spelling and executed by another, and the bookkeeping has to
    # survive the trip either way.
    it 'keeps the bookkeeping of a statement prepared under another spelling' do
      allow(connection).to receive(:sync_prepare)
      allow(connection).to receive(:async_exec_prepared).and_return(pg_result)

      wrapper.sync_prepare('insert_user', 'INSERT INTO users (name, ssn) VALUES ($1, $2)')
      wrapper.async_exec_prepared('insert_user', %w[Jo 123-45-6789])

      expect(plugin.method_names).to eq(['connection.prepare', 'connection.exec_prepared'])
      expect(wrapper.instance_variable_get(:@prepared_on)).to eq({ 'insert_user' => connection })
    end

    it 'publishes the SQL a statement was prepared with under any spelling' do
      allow(connection).to receive(:sync_prepare)
      allow(connection).to receive(:async_exec_prepared).and_return(pg_result)

      wrapper.sync_prepare('insert_user', 'INSERT INTO users (name, ssn) VALUES ($1, $2)')
      wrapper.async_exec_prepared('insert_user', %w[Jo 123-45-6789])

      expect(plugin.sql_for('connection.exec_prepared')).to eq(['INSERT INTO users (name, ssn) VALUES ($1, $2)'])
    end

    it 'says it responds to the spellings it translates' do
      expect(wrapper).to respond_to(:sync_exec, :async_exec_params, :notifies_wait, :loread)
    end

    # A spelling the table does not list, which is what a future pg release adding one looks like. The
    # connection here is a plain double rather than a verifying one for that reason: the whole point is a
    # name the installed gem does not define, which a verifying double would refuse.
    it 'recognizes an unlisted sync_ spelling by what is left when the prefix is removed' do
      connection = double('PG::Connection', sync_lo_read: 'data')
      container, plugin = build_recording_container(connection)
      wrapper = build_wrapper(container)

      expect(wrapper.sync_lo_read(0, 4)).to eq('data')
      expect(plugin.method_names).to eq(['connection.lo_read'])
      expect(connection).to have_received(:sync_lo_read).with(0, 4)
    end

    it 'still refuses an unlisted spelling that belongs to another connection' do
      connection = double('PG::Connection', sync_lo_read: 'data')
      wrapper = build_wrapper(build_recording_container(connection).first)
      wrapper.instance_variable_set(:@lo_conn, double('PG::Connection'))

      expect { wrapper.sync_lo_read(0, 4) }
        .to raise_error(AwsRubyDatabaseDriverWrapper::Errors::AwsError, /old connection/)
      expect(connection).not_to have_received(:sync_lo_read)
    end
  end

  # The dialect's list is what enrolls a call in the pipeline and what failover subscribes to, and
  # OPERATIONS is what says how each of those calls is performed. Neither is derivable from the other,
  # so they are checked against each other here rather than by eye.
  describe 'OPERATIONS' do
    let(:operations) { described_class::OPERATIONS }
    let(:listed) do
      AwsRubyDatabaseDriverWrapper::DriverDialects::PgDriverDialect::NETWORK_BOUND_METHODS
        .select { |entry| entry.start_with?('connection.') }
        .map { |entry| entry.delete_prefix('connection.').to_sym }
    end

    it 'describes every connection call the dialect takes through the pipeline' do
      expect(listed - operations.keys).to be_empty
    end

    it 'describes nothing the dialect does not take through the pipeline' do
      expect(operations.keys - listed).to be_empty
    end

    it 'gives every operation a name the pipeline can check the bounded connection against' do
      expect(operations.values.map { |spec| spec[:method] })
        .to all(be_a(AwsRubyDatabaseDriverWrapper::MethodInfo))
    end

    # An operation that reads what an earlier call left behind has to be checked against the connection
    # it was left on, which the pipeline only does when the entry says so.
    it 'has the pipeline check the connection of every bound operation' do
      unchecked = operations.select { |_, spec| spec[:bound_to] }.reject { |_, spec| spec[:method].check_bounded_connection }

      expect(unchecked).to be_empty
    end

    it 'names a hook it defines for every operation that leaves something behind' do
      hooks = operations.values.flat_map { |spec| Array(spec[:after]) }.uniq

      expect(hooks.reject { |hook| described_class.private_method_defined?(hook) }).to be_empty
    end

    it 'covers every spelling with an operation it describes' do
      uncovered = described_class::OPERATION_BY_SPELLING.reject { |_, operation| operations.key?(operation) }

      expect(uncovered).to be_empty
    end

    # An operation names the SQL among its own arguments or takes it from whatever it is bound to, and
    # never both, since an entry that said both would silently publish only the first.
    it 'takes the SQL of an operation from one place only' do
      expect(operations.select { |_, spec| spec[:sql_at] && spec[:bound_to] }).to be_empty
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

    # The statement only exists on the connection it was prepared on, which is the whole reason the
    # call is entered under a name the pipeline knows rather than as a bare string.
    it 'is refused when the statement it names belongs to another connection' do
      wrapper.instance_variable_set(:@prepared_on, { 'insert_user' => instance_double(PG::Connection) })
      allow(connection).to receive(:close_prepared)

      expect { wrapper.close_prepared('insert_user') }
        .to raise_error(AwsRubyDatabaseDriverWrapper::Errors::AwsError, /old connection/)
    end

    it 'forgets a statement it closed' do
      allow(connection).to receive(:prepare)
      allow(connection).to receive(:close_prepared)

      wrapper.prepare('insert_user', 'INSERT INTO users (name, ssn) VALUES ($1, $2)')
      wrapper.close_prepared('insert_user')

      expect(wrapper.instance_variable_get(:@prepared_on)).to be_empty
    end

    it 'forgets the SQL of a statement it closed' do
      allow(connection).to receive(:prepare)
      allow(connection).to receive(:close_prepared)
      allow(connection).to receive(:exec_prepared).and_return(pg_result)

      wrapper.prepare('insert_user', 'INSERT INTO users (name, ssn) VALUES ($1, $2)')
      wrapper.close_prepared('insert_user')
      wrapper.exec_prepared('insert_user')

      expect(plugin.sql_for('connection.exec_prepared')).to eq([nil])
    end

    it 'is refused when a large object was opened on another connection' do
      wrapper.instance_variable_set(:@lo_conn, instance_double(PG::Connection))
      allow(connection).to receive(:loread)

      expect { wrapper.loread(0, 4) }.to raise_error(AwsRubyDatabaseDriverWrapper::Errors::AwsError, /old connection/)
    end

    it 'allows a large object read on the connection it was opened on' do
      allow(connection).to receive(:lo_open).and_return(0)
      allow(connection).to receive(:loread).and_return('data')

      wrapper.lo_open(1234)

      expect(wrapper.loread(0, 4)).to eq('data')
      expect(plugin.method_names).to eq(['connection.lo_open', 'connection.lo_read'])
    end

    it 'forgets a large object descriptor it closed' do
      allow(connection).to receive(:lo_open).and_return(0)
      allow(connection).to receive(:lo_close)

      wrapper.lo_open(1234)
      wrapper.lo_close(0)

      expect(wrapper.instance_variable_get(:@lo_conn)).to be_nil
    end

    # A pending exchange can only be continued on the connection it was started on, and it is a call
    # through method_missing that starts this one.
    it 'remembers the connection a description was sent on' do
      allow(connection).to receive(:prepare)
      allow(connection).to receive(:send_describe_prepared)

      wrapper.prepare('insert_user', 'INSERT INTO users (name, ssn) VALUES ($1, $2)')
      wrapper.send_describe_prepared('insert_user')

      expect(wrapper.instance_variable_get(:@async_conn)).to eq(connection)
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

    it 'refuses to continue a pending exchange on another connection' do
      wrapper.instance_variable_set(:@async_conn, instance_double(PG::Connection))
      allow(connection).to receive(:pipeline_sync)

      expect { wrapper.pipeline_sync }.to raise_error(AwsRubyDatabaseDriverWrapper::Errors::AwsError, /old connection/)
    end

    it 'drops a pending exchange whose results were discarded' do
      allow(connection).to receive(:send_query)
      allow(connection).to receive(:discard_results)

      wrapper.send_query('SELECT ssn FROM users')
      wrapper.discard_results

      expect(wrapper.instance_variable_get(:@async_conn)).to be_nil
    end

    it 'hands a call that does not talk to the server straight to the driver' do
      allow(connection).to receive(:escape_string).and_return('Jo')

      expect(wrapper.escape_string('Jo')).to eq('Jo')
      expect(plugin.method_names).to be_empty
    end
  end

  # Nothing else in the call chain has any SQL to publish, and a plugin that inspects statements must
  # not be handed the SQL of a statement that is already finished.
  describe 'a call that has no SQL of its own' do
    it 'publishes no SQL' do
      allow(connection).to receive(:exec).and_return(pg_result)
      allow(connection).to receive(:consume_input)

      wrapper.exec('SELECT ssn FROM users')
      wrapper.consume_input

      expect(plugin.sql_for('connection.consume_input')).to eq([nil])
    end
  end
end
