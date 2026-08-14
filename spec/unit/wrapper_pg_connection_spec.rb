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
RSpec.describe AwsRubyDatabaseDriverWrapper::WrapperPgConnection do
  let(:pg_result) { driver_result(PG::Result, 'PgResult') }
  # A verifying double, so that a call the wrapper makes on a method pg does not define fails here
  # rather than against a real server.
  let(:connection) { instance_double(PG::Connection) }
  let(:recorded) { build_recording_container(connection) }
  let(:container) { recorded.first }
  let(:plugin) { recorded.last }
  subject(:wrapper) do
    wrapper = described_class.allocate
    wrapper.instance_variable_set(:@service_container, container)
    wrapper.instance_variable_set(:@prepared_on, {})
    wrapper.instance_variable_set(:@async_conn, nil)
    wrapper.instance_variable_set(:@copy_conn, nil)
    wrapper.instance_variable_set(:@lo_conn, nil)
    # Which methods go through the pipeline is the dialect's answer, and it is memoized here, so it is
    # set rather than reached for through a service container that is not connected to anything.
    wrapper.instance_variable_set(
      :@network_bound_methods, AwsRubyDatabaseDriverWrapper::DriverDialects::PgDriverDialect::NETWORK_BOUND_METHODS
    )
    wrapper
  end

  # pg gives most of its calls more than one spelling, and an application is free to use any of them.
  # A spelling this class does not define is performed by the method that does define the operation,
  # so that it enters the pipeline under the same name and keeps the same bookkeeping. Before that, an
  # unrecognized spelling was handed straight to the driver, which took the statement it carried past
  # every plugin.
  describe 'the other spellings pg gives a call' do
    it 'takes query through the pipeline as the exec it is named for' do
      allow(connection).to receive(:query).and_return(pg_result)
      wrapper.query('INSERT INTO users (name, ssn) VALUES ($1, $2)', %w[Jo 123-45-6789])

      expect(plugin.method_names).to eq(['connection.exec'])
    end

    it 'takes async_query through the pipeline' do
      allow(connection).to receive(:exec).and_return(pg_result)
      wrapper.async_query('SELECT ssn FROM users')

      expect(plugin.method_names).to eq(['connection.exec'])
    end

    it 'takes sync_exec_params through the pipeline' do
      allow(connection).to receive(:exec_params).and_return(pg_result)
      wrapper.sync_exec_params('SELECT ssn FROM users WHERE name = $1', ['Jo'])

      expect(plugin.method_names).to eq(['connection.exec_params'])
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

      expect(plugin.method_names).to eq(['connection.exec_params', 'result.to_a'])
    end

    # The statement was prepared by one spelling and executed by another, and the bookkeeping has to
    # survive the trip either way.
    it 'keeps the bookkeeping of a statement prepared under another spelling' do
      allow(connection).to receive(:prepare)
      allow(connection).to receive(:exec_prepared).and_return(pg_result)

      wrapper.sync_prepare('insert_user', 'INSERT INTO users (name, ssn) VALUES ($1, $2)')
      wrapper.async_exec_prepared('insert_user', %w[Jo 123-45-6789])

      expect(plugin.method_names).to eq(['connection.prepare', 'connection.exec_prepared'])
      expect(wrapper.instance_variable_get(:@prepared_on)).to eq({ 'insert_user' => connection })
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

    it 'is refused when a large object was opened on another connection' do
      wrapper.instance_variable_set(:@lo_conn, instance_double(PG::Connection))
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

  # pg has no instance ping: PG::Connection.ping is a class method that opens a connection of its own
  # to try a set of options out. Calling it on a connection raised NoMethodError, so the dialect
  # answers it with a trivial statement instead.
  describe '#ping' do
    it 'asks the dialect rather than the connection' do
      container.dialect_service = instance_double(
        AwsRubyDatabaseDriverWrapper::Services::DialectService,
        driver_dialect: AwsRubyDatabaseDriverWrapper::DriverDialects::PgDriverDialect.new
      )
      allow(connection).to receive(:exec).and_return(driver_result(PG::Result, 'PingResult'))

      expect(wrapper.ping).to be(true)
      expect(plugin.method_names).to eq(['connection.ping'])
    end
  end
end
