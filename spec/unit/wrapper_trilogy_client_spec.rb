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
require 'aws_advanced_ruby_driver_wrapper/trilogy'
require 'aws_advanced_ruby_driver_wrapper/driver_dialects/trilogy_driver_dialect'

# Every call that talks to the server has to reach the plugins under a name trilogy answers to, and a
# call that reads what is left of a statement has to be refused on any connection but the one the
# statement was sent on.
RSpec.describe AwsAdvancedRubyDriverWrapper::WrapperTrilogyClient do
  # A verifying double, so that a call the wrapper makes on a method trilogy does not define fails
  # here rather than against a real server.
  let(:connection) { instance_double(Trilogy) }
  let(:trilogy_result) { Trilogy::Result.new(%w[id], [[1]], 0.0, false, 0, 0) }
  let(:recorded) { build_recording_container(connection) }
  let(:container) { recorded.first }
  let(:plugin) { recorded.last }
  subject(:client) do
    client = described_class.allocate
    client.instance_variable_set(:@service_container, container)
    client.instance_variable_set(:@query_conn, nil)
    # Which methods go through the pipeline is the dialect's answer, and it is memoized here, so it is
    # set rather than reached for through a service container that is not connected to anything.
    client.instance_variable_set(
      :@network_bound_methods, AwsAdvancedRubyDriverWrapper::DriverDialects::TrilogyDriverDialect::NETWORK_BOUND_METHODS
    )
    client
  end

  describe '.new' do
    before do
      allow(AwsAdvancedRubyDriverWrapper::Utils::ConnectionConfigParser).to receive(:parse).and_raise('stop')
    end

    # Trilogy.new takes its options as one hash, so the wrapper takes them the same way.
    it 'takes its options as a hash, as Trilogy.new does' do
      expect { described_class.new({ host: 'db.example.com', wrapper_plugins: 'failover' }) }.to raise_error('stop')

      expect(AwsAdvancedRubyDriverWrapper::Utils::ConnectionConfigParser)
        .to have_received(:parse).with(:trilogy, host: 'db.example.com', wrapper_plugins: 'failover')
    end

    it 'also takes them as keyword arguments' do
      expect { described_class.new(host: 'db.example.com') }.to raise_error('stop')

      expect(AwsAdvancedRubyDriverWrapper::Utils::ConnectionConfigParser)
        .to have_received(:parse).with(:trilogy, host: 'db.example.com')
    end
  end

  describe '#query' do
    it 'runs through the pipeline and publishes the SQL it was called with' do
      allow(connection).to receive(:query).and_return(trilogy_result)

      client.query('SELECT ssn FROM users')

      expect(plugin.method_names).to eq(['connection.query'])
      expect(plugin.sql_for('connection.query')).to eq(['SELECT ssn FROM users'])
    end

    # A Trilogy::Result is read off the wire in full before it is returned, so reading its rows never
    # talks to the server, and it is handed back as the driver returned it.
    it 'returns the driver result itself' do
      allow(connection).to receive(:query).and_return(trilogy_result)

      expect(client.query('SELECT 1')).to equal(trilogy_result)
    end

    it 'publishes SQL that is not UTF-8 as UTF-8, and sends it as the application wrote it' do
      sql = "SELECT 'grün'".encode('UTF-16BE')
      allow(connection).to receive(:query).and_return(trilogy_result)

      client.query(sql)

      expect(plugin.sql_for('connection.query')).to eq(["SELECT 'grün'"])
      expect(connection).to have_received(:query).with(equal(sql))
    end
  end

  # ActiveRecord reads every result set a statement leaves before it sends the next one.
  describe 'a statement that leaves more than one result set' do
    before do
      allow(connection).to receive(:query).and_return(trilogy_result)
      allow(connection).to receive(:next_result).and_return(trilogy_result)
      allow(connection).to receive(:more_results_exist?).and_return(true)
    end

    it 'reads each further result set through the pipeline, publishing the SQL that was sent' do
      client.query('CALL report()')
      client.next_result

      expect(plugin.method_names).to eq(['connection.query', 'connection.next_result'])
      expect(plugin.sql_for('connection.next_result')).to eq(['CALL report()'])
    end

    it 'refuses to read one on any connection but the one the statement was sent on' do
      client.query('CALL report()')
      client.instance_variable_set(:@query_conn, instance_double(Trilogy))

      expect { client.next_result }.to raise_error(AwsAdvancedRubyDriverWrapper::Errors::AwsError, /old connection/)
    end

    it 'refuses to drain one on any connection but the one the statement was sent on' do
      allow(connection).to receive(:abandon_results!)
      client.instance_variable_set(:@query_conn, instance_double(Trilogy))

      expect { client.abandon_results! }
        .to raise_error(AwsAdvancedRubyDriverWrapper::Errors::AwsError, /old connection/)
    end

    it 'answers whether more results are pending straight from the driver' do
      expect(client.more_results_exist?).to be true
      expect(plugin.method_names).to be_empty
    end
  end

  describe 'a call that talks to the server' do
    it 'pings through the pipeline' do
      allow(connection).to receive(:ping).and_return(true)

      expect(client.ping).to be true
      expect(plugin.method_names).to eq(['connection.ping'])
    end

    it 'closes through the pipeline' do
      allow(connection).to receive(:close)

      client.close

      expect(plugin.method_names).to eq(['connection.close'])
    end

    it 'changes the database through the pipeline' do
      allow(connection).to receive(:change_db).and_return(true)

      client.change_db('other')

      expect(connection).to have_received(:change_db).with('other')
      expect(plugin.method_names).to eq(['connection.change_db'])
    end

    it 'sends a server option through the pipeline' do
      allow(connection).to receive(:set_server_option).and_return(true)

      client.set_server_option(Trilogy::SET_SERVER_MULTI_STATEMENTS_ON)

      expect(plugin.method_names).to eq(['connection.set_server_option'])
    end
  end

  describe 'a call that trilogy answers without the server' do
    it 'escapes straight through the driver' do
      allow(connection).to receive(:escape).with("it's").and_return("it\\'s")

      expect(client.escape("it's")).to eq("it\\'s")
      expect(plugin.method_names).to be_empty
    end

    it 'sets the query flags on the driver' do
      allow(connection).to receive(:query_flags=)

      client.query_flags = Trilogy::QUERY_FLAGS_DEFAULT

      expect(connection).to have_received(:query_flags=).with(Trilogy::QUERY_FLAGS_DEFAULT)
      expect(plugin.method_names).to be_empty
    end

    it 'answers a method trilogy does not define with NoMethodError' do
      expect { client.no_such_method }.to raise_error(NoMethodError)
    end
  end

  describe '#inspect' do
    it 'does not expose the connection config' do
      expect(client.inspect).to match(/\A#<AwsAdvancedRubyDriverWrapper::WrapperTrilogyClient:0x\h+>\z/)
    end
  end
end
